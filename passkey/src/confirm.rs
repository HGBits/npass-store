//! Presença do usuário (UP/UV).
//!
//! Sem isso, qualquer página poderia pedir uma assinatura em silêncio. Ordem:
//!   1. `--confirm-cmd` / NPASS_PASSKEY_CONFIRM: comando de shell; sai 0 = permitir
//!      (recebe NPASS_PASSKEY_RP, NPASS_PASSKEY_USER e NPASS_PASSKEY_INFO no ambiente);
//!   2. zenity ou kdialog, se existirem;
//!   3. o terminal (/dev/tty) de quem iniciou o daemon, se houver;
//!   4. nada disponível: NEGA. Não existe modo "aprovar tudo".

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub enum Confirm {
    /// Comando de shell do usuário.
    Shell(String),
    Zenity,
    Kdialog,
    /// Pergunta no terminal (/dev/tty) de quem iniciou o daemon.
    Tty,
    /// Não há como perguntar: nega.
    Deny,
}

const TIMEOUT: Duration = Duration::from_secs(60);

fn have(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

impl Confirm {
    pub fn detect(shell: Option<String>) -> Self {
        if let Some(c) = shell.filter(|c| !c.trim().is_empty()) {
            return Confirm::Shell(c);
        }
        if have("zenity") {
            Confirm::Zenity
        } else if have("kdialog") {
            Confirm::Kdialog
        } else if std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty").is_ok() {
            Confirm::Tty
        } else {
            Confirm::Deny
        }
    }

    pub fn describe(&self) -> &'static str {
        match self {
            Confirm::Shell(_) => "comando do usuário",
            Confirm::Zenity => "zenity",
            Confirm::Kdialog => "kdialog",
            Confirm::Tty => "terminal (/dev/tty)",
            Confirm::Deny => "nenhum diálogo disponível: tudo será NEGADO",
        }
    }

    /// true = o usuário permitiu.
    pub fn ask(&self, info: &str, user: Option<&str>, rp_id: &str) -> bool {
        let who = user.unwrap_or("(sem nome)");
        let text = format!("npass passkey\n\nSite: {rp_id}\nConta: {who}\n{info}\n\nPermitir?");
        let mut cmd = match self {
            Confirm::Deny => {
                eprintln!("npass-passkeyd: sem diálogo de confirmação; negado ({rp_id}). Use --confirm-cmd ou instale zenity/kdialog.");
                return false;
            }
            Confirm::Tty => return ask_tty(&text),
            Confirm::Shell(sh) => {
                let mut c = Command::new("sh");
                c.arg("-c").arg(sh);
                c
            }
            Confirm::Zenity => {
                let mut c = Command::new("zenity");
                c.args(["--question", "--no-markup", "--title=npass passkey", "--timeout=55"])
                    .arg(format!("--text={text}"));
                c
            }
            Confirm::Kdialog => {
                let mut c = Command::new("kdialog");
                c.args(["--title", "npass passkey", "--yesno"]).arg(&text);
                c
            }
        };
        cmd.env("NPASS_PASSKEY_RP", rp_id)
            .env("NPASS_PASSKEY_USER", who)
            .env("NPASS_PASSKEY_INFO", info)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("npass-passkeyd: não consegui abrir o diálogo: {e}");
                return false;
            }
        };
        let start = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(st)) => return st.success(),
                Ok(None) if start.elapsed() > TIMEOUT => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                Err(_) => return false,
            }
        }
    }
}

/// Pergunta no /dev/tty: só "s"/"sim"/"y"/"yes" permite; timeout e EOF negam.
fn ask_tty(text: &str) -> bool {
    use std::io::Write;
    use std::os::fd::AsRawFd;
    let Ok(mut tty) = std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty") else {
        return false;
    };
    let _ = write!(tty, "\n{text} [s/N] ");
    let _ = tty.flush();
    let mut pfd = libc::pollfd { fd: tty.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: pfd é válido, nfds = 1.
    let n = unsafe { libc::poll(&mut pfd, 1, TIMEOUT.as_millis() as libc::c_int) };
    if n <= 0 {
        return false;
    }
    let mut line = String::new();
    let mut buf = [0u8; 1];
    use std::io::Read;
    while tty.read(&mut buf).map(|n| n == 1).unwrap_or(false) && buf[0] != b'\n' {
        line.push(buf[0] as char);
        if line.len() > 16 {
            break;
        }
    }
    matches!(line.trim().to_lowercase().as_str(), "s" | "sim" | "y" | "yes")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_exit_code_decide() {
        assert!(Confirm::Shell("exit 0".into()).ask("x", Some("u"), "a.com"));
        assert!(!Confirm::Shell("exit 1".into()).ask("x", Some("u"), "a.com"));
    }

    #[test]
    fn shell_recebe_rp_no_ambiente() {
        let c = Confirm::Shell(r#"[ "$NPASS_PASSKEY_RP" = "site.test" ]"#.into());
        assert!(c.ask("x", None, "site.test"));
        assert!(!c.ask("x", None, "outro.test"));
    }

    #[test]
    fn deny_nega() {
        assert!(!Confirm::Deny.ask("x", None, "a"));
    }
}
