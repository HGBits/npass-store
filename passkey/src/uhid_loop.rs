//! UHID + CTAPHID + CTAP2: o dispositivo FIDO virtual que o navegador enxerga.

use soft_fido2::{Authenticator, AuthenticatorCallbacks, AuthenticatorConfig};
use soft_fido2_transport::{Cmd, CommandHandler, CtapHidHandler, Packet, UhidDevice};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    // SAFETY: o handler só faz um store atômico (async-signal-safe).
    unsafe {
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
    }
}

/// Entrega ao CTAP2 só os comandos CBOR; U2F/MSG não é oferecido.
pub struct CtapHandler<C: AuthenticatorCallbacks> {
    auth: Mutex<Authenticator<C>>,
}

impl<C: AuthenticatorCallbacks> CtapHandler<C> {
    pub fn new(auth: Authenticator<C>) -> Self {
        Self { auth: Mutex::new(auth) }
    }
}

impl<C: AuthenticatorCallbacks> CommandHandler for CtapHandler<C> {
    fn handle_command(&mut self, cmd: Cmd, data: &[u8]) -> soft_fido2_transport::Result<Vec<u8>> {
        if cmd != Cmd::Cbor {
            return Err(soft_fido2_transport::Error::InvalidCommand);
        }
        let mut auth = self
            .auth
            .lock()
            .map_err(|_| soft_fido2_transport::Error::Other("authenticator lock".into()))?;
        let mut response = Vec::new();
        auth.handle(data, &mut response)
            .map_err(|_| soft_fido2_transport::Error::Other("ctap command failed".into()))?;
        Ok(response)
    }
}

pub fn run<C: AuthenticatorCallbacks + 'static>(
    callbacks: C,
    config: AuthenticatorConfig,
) -> Result<(), String> {
    let auth = Authenticator::with_config(callbacks, config.clone())
        .map_err(|e| format!("não consegui criar o autenticador: {e:?}"))?;
    let device = UhidDevice::create_fido_device_with_ids(
        config.device_name.as_deref(),
        config.vendor_id,
        config.product_id,
        config.device_version,
    )
    .map_err(|e| {
        format!(
            "não consegui criar o dispositivo UHID ({e:?}). Confira: `sudo modprobe uhid`, \
             permissão em /dev/uhid (regra udev, grupo) e que /dev/uhid existe"
        )
    })?;
    let mut handler = CtapHidHandler::new(CtapHandler::new(auth));
    install_signal_handlers();
    let fd = device.as_raw_fd();

    while !STOP.load(Ordering::SeqCst) {
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: pfd é um struct válido e nfds = 1.
        let n = unsafe { libc::poll(&mut pfd, 1, 250) };
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("poll: {}", std::io::Error::last_os_error()));
        }
        if n == 0 {
            continue;
        }
        loop {
            let mut buf = [0u8; 64];
            match device.read_packet(&mut buf) {
                Ok(Some(_)) => {
                    let replies = match handler.process_packet(Packet::from_bytes(buf)) {
                        Ok(r) => r,
                        Err(e) => {
                            eprintln!("npass-passkeyd: pacote CTAPHID rejeitado: {e:?}");
                            continue;
                        }
                    };
                    for p in replies {
                        if let Err(e) = device.write_packet(p.as_bytes()) {
                            eprintln!("npass-passkeyd: falha ao escrever no UHID: {e:?}");
                        }
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    eprintln!("npass-passkeyd: leitura do UHID: {e:?}");
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    break;
                }
            }
        }
    }
    Ok(())
}
