use npass_passkeyd::backend::NpassBackend;
use npass_passkeyd::callbacks::NpassCallbacks;
use npass_passkeyd::confirm::Confirm;
use npass_passkeyd::PROTOCOL;

const USAGE: &str = "\
npass-passkeyd - autenticador FIDO2 virtual (UHID) com o npass como único armazenamento

Não execute direto: use `npass passkey serve ID`, que valida este helper antes.

uso: npass-passkeyd --id ID [--auto-approve] [--confirm-cmd CMD]
     npass-passkeyd --protocol | --version | --help

  --id ID            identidade do npass onde as passkeys ficam
  --confirm-cmd CMD  comando de shell para pedir presença (sai 0 = permitir);
                     também via NPASS_PASSKEY_CONFIRM. Padrão: zenity ou kdialog.
  --auto-approve     aprova tudo sem perguntar (só para testes/headless)
ambiente: NPASS_BIN (executável do npass), NPASS_STORE, NPASS_GPG";

fn main() {
    let mut id: Option<String> = None;
    let mut auto = false;
    let mut confirm_cmd = std::env::var("NPASS_PASSKEY_CONFIRM").ok();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--protocol" => {
                println!("npass-passkeyd-protocol {PROTOCOL}");
                return;
            }
            "--version" => {
                println!("npass-passkeyd {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            "--id" => id = args.next(),
            "--auto-approve" => auto = true,
            "--confirm-cmd" => confirm_cmd = args.next(),
            other => {
                eprintln!("npass-passkeyd: opção desconhecida: {other}\n\n{USAGE}");
                std::process::exit(2);
            }
        }
    }
    let Some(id) = id.filter(|s| !s.is_empty()) else {
        eprintln!("npass-passkeyd: falta --id\n\n{USAGE}");
        std::process::exit(2);
    };
    let npass = std::env::var("NPASS_BIN").unwrap_or_else(|_| "npass".into());

    let confirm = Confirm::detect(auto, confirm_cmd);
    eprintln!("npass-passkeyd: identidade '{id}', confirmação: {}", confirm.describe());

    let callbacks = NpassCallbacks::new(NpassBackend::new(npass, id), confirm);
    let config = npass_passkeyd::authenticator_config();

    #[cfg(target_os = "linux")]
    {
        eprintln!("npass-passkeyd: dispositivo FIDO virtual no ar (Ctrl+C para sair)");
        if let Err(e) = npass_passkeyd::uhid_loop::run(callbacks, config) {
            eprintln!("npass-passkeyd: {e}");
            std::process::exit(1);
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (callbacks, config);
        eprintln!("npass-passkeyd: só Linux (UHID)");
        std::process::exit(1);
    }
}
