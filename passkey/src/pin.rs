//! Entrada do PIN (alfanumérico, 4 a 64 caracteres) quando a política pede.
//!
//! O PIN é conferido pelo `npass passkey pin verify` (que guarda o hash em Fido/ e conta os
//! erros). Aqui só se pergunta. Ordem: `--pin-cmd`/NPASS_PASSKEY_PIN_CMD (shell; PIN no stdout),
//! zenity, kdialog, terminal sem eco (/dev/tty); sem nada disso, não há como pedir: a
//! operação é negada.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(60);

/// PIN em memória: zerado ao ser descartado.
pub struct Secret(String);

impl Secret {
    pub fn new(s: String) -> Self {
        Secret(s)
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        // SAFETY: só sobrescreve com zeros os bytes que a String já possui.
        unsafe {
            for b in self.0.as_bytes_mut() {
                std::ptr::write_volatile(b, 0);
            }
        }
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret(***)")
    }
}

#[derive(Debug, Clone)]
pub enum PinPrompt {
    Shell(String),
    Zenity,
    Kdialog,
    Tty,
    /// Nenhum jeito de perguntar.
    None,
}

fn have(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

impl PinPrompt {
    pub fn detect(shell: Option<String>) -> Self {
        if let Some(c) = shell.filter(|c| !c.trim().is_empty()) {
            return PinPrompt::Shell(c);
        }
        if have("zenity") {
            PinPrompt::Zenity
        } else if have("kdialog") {
            PinPrompt::Kdialog
        } else if std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty").is_ok() {
            PinPrompt::Tty
        } else {
            PinPrompt::None
        }
    }

    pub fn describe(&self) -> &'static str {
        match self {
            PinPrompt::Shell(_) => "comando do usuário",
            PinPrompt::Zenity => "zenity",
            PinPrompt::Kdialog => "kdialog",
            PinPrompt::Tty => "terminal (/dev/tty)",
            PinPrompt::None => "nenhum meio de pedir o PIN: operações com PIN serão NEGADAS",
        }
    }

    /// Pede o PIN. `None` = cancelado, vazio, tempo esgotado ou sem meio de perguntar.
    pub fn ask(&self, rp_id: &str, user: Option<&str>, tries_left: u8) -> Option<Secret> {
        let who = user.unwrap_or("(sem nome)");
        let title = format!("npass passkey: PIN para {rp_id} ({who}) - restam {tries_left} tentativa(s)");
        let mut cmd = match self {
            PinPrompt::None => {
                eprintln!("npass-passkeyd: PIN exigido, mas não há como pedi-lo; negado ({rp_id}). Use --pin-cmd ou instale zenity/kdialog.");
                return None;
            }
            PinPrompt::Tty => return ask_tty(&title),
            PinPrompt::Shell(sh) => {
                let mut c = Command::new("sh");
                c.arg("-c").arg(sh);
                c
            }
            PinPrompt::Zenity => {
                let mut c = Command::new("zenity");
                c.args(["--password", "--title"]).arg(&title);
                c
            }
            PinPrompt::Kdialog => {
                let mut c = Command::new("kdialog");
                c.args(["--title", "npass passkey", "--password"]).arg(&title);
                c
            }
        };
        cmd.env("NPASS_PASSKEY_RP", rp_id)
            .env("NPASS_PASSKEY_USER", who)
            .env("NPASS_PASSKEY_TRIES_LEFT", tries_left.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().ok()?;
        let start = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(st)) if st.success() => break,
                Ok(Some(_)) | Err(_) => return None,
                Ok(None) if start.elapsed() > TIMEOUT => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
        let mut out = String::new();
        child.stdout.take()?.read_to_string(&mut out).ok()?;
        let pin = out.trim_end_matches(['\n', '\r']).to_string();
        out.clear();
        (!pin.is_empty()).then(|| Secret::new(pin))
    }
}

/// Lê uma linha do /dev/tty com eco desligado.
fn ask_tty(title: &str) -> Option<Secret> {
    use std::io::Write;
    use std::os::fd::AsRawFd;
    let mut tty = std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty").ok()?;
    let fd = tty.as_raw_fd();
    // SAFETY: termios é plain-old-data; fd é um terminal válido durante toda a função.
    let mut old: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd, &mut old) } != 0 {
        return None;
    }
    let mut quiet = old;
    quiet.c_lflag &= !(libc::ECHO as libc::tcflag_t);
    if unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &quiet) } != 0 {
        return None;
    }
    let _ = write!(tty, "\n{title}\nPIN: ");
    let _ = tty.flush();
    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    let ready = unsafe { libc::poll(&mut pfd, 1, TIMEOUT.as_millis() as libc::c_int) } > 0;
    let mut line = String::new();
    if ready {
        let mut b = [0u8; 1];
        while tty.read(&mut b).map(|n| n == 1).unwrap_or(false) && b[0] != b'\n' {
            line.push(b[0] as char);
            if line.len() > 256 {
                break;
            }
        }
    }
    unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &old) };
    let _ = writeln!(tty);
    (ready && !line.is_empty()).then(|| Secret::new(line))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comando_devolve_o_pin_sem_a_quebra_de_linha() {
        let p = PinPrompt::Shell("echo Abc123".into());
        assert_eq!(p.ask("a.com", Some("u"), 5).unwrap().as_str(), "Abc123");
    }

    #[test]
    fn cancelado_ou_vazio_nao_e_pin() {
        assert!(PinPrompt::Shell("exit 1".into()).ask("a", None, 5).is_none());
        assert!(PinPrompt::Shell("echo".into()).ask("a", None, 5).is_none());
        assert!(PinPrompt::None.ask("a", None, 5).is_none());
    }

    #[test]
    fn comando_recebe_rp_e_tentativas() {
        let p = PinPrompt::Shell(r#"[ "$NPASS_PASSKEY_RP" = x.test ] && [ "$NPASS_PASSKEY_TRIES_LEFT" = 3 ] && echo ok1234"#.into());
        assert!(p.ask("x.test", None, 3).is_some());
        assert!(p.ask("x.test", None, 2).is_none());
    }
}
