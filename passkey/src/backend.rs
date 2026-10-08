//! Ponte para o armazenamento: sempre `npass passkey <cmd> ID ...`.
//!
//! Chamar o executável `npass` (e não o arquivo da extensão) faz cada operação
//! passar de novo pelas portas do npass para extensões (assinatura, chave sua).

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use std::fmt;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub rp_id: String,
    pub login: String,
    pub blob: String,
}

#[derive(Debug, Clone)]
pub struct BackendError(pub String);

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for BackendError {}

/// Política de exigência de PIN (por identidade, em Fido/.pin.gpg).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    /// Nunca pede PIN, mesmo que exista.
    Nunca,
    /// Pede PIN se houver um E o site pedir verificação do usuário.
    Opcional,
    /// Toda operação exige PIN; sem PIN definido, nega.
    Requerido,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinStatus {
    pub policy: Policy,
    pub set: bool,
    pub tries_left: u8,
    pub blocked: bool,
}

impl PinStatus {
    /// Sem registro: política "opcional", sem PIN.
    pub fn unset() -> Self {
        Self { policy: Policy::Opcional, set: false, tries_left: 5, blocked: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinCheck {
    Ok,
    Wrong { tries_left: u8 },
    Blocked,
    NotSet,
}

/// Saída de `npass passkey pin status`: linhas `chave valor`.
pub fn parse_pin_status(out: &str) -> Result<PinStatus, BackendError> {
    let mut st = PinStatus::unset();
    let mut seen = 0;
    for l in out.lines() {
        let mut p = l.splitn(2, ' ');
        match (p.next(), p.next()) {
            (Some("policy"), Some(v)) => {
                st.policy = match v {
                    "nunca" => Policy::Nunca,
                    "opcional" => Policy::Opcional,
                    "requerido" => Policy::Requerido,
                    _ => return Err(BackendError(format!("política desconhecida: {v}"))),
                };
                seen += 1;
            }
            (Some("set"), Some(v)) => {
                st.set = v == "1";
                seen += 1;
            }
            (Some("tries-left"), Some(v)) => {
                st.tries_left = v.trim().parse().unwrap_or(0);
                seen += 1;
            }
            (Some("blocked"), Some(v)) => {
                st.blocked = v == "1";
                seen += 1;
            }
            _ => {}
        }
    }
    if seen < 4 {
        return Err(BackendError("saída de 'pin status' incompleta".into()));
    }
    Ok(st)
}

/// O que o daemon precisa do armazenamento. Só a implementação `NpassBackend`
/// guarda algo (no npass); os testes usam uma em memória.
pub trait Backend: Send + Sync {
    /// Entradas do índice (descoberta), opcionalmente de um RP.
    fn list(&self, rp_id: Option<&str>) -> Result<Vec<Entry>, BackendError>;
    /// Credencial (CBOR) de um blob, já verificado e decifrado pelo npass.
    fn load(&self, blob: &str) -> Result<Vec<u8>, BackendError>;
    /// Guarda uma credencial nova; devolve o nome do blob.
    fn store(&self, rp_id: &str, login: &str, credential: &[u8]) -> Result<String, BackendError>;
    fn remove(&self, blob: &str) -> Result<(), BackendError>;
    /// Política, se há PIN e quantas tentativas restam.
    fn pin_status(&self) -> Result<PinStatus, BackendError>;
    /// Confere o PIN (o backend conta o erro e bloqueia no 5º).
    fn pin_verify(&self, pin: &str) -> Result<PinCheck, BackendError>;
}

pub struct NpassBackend {
    bin: PathBuf,
    id: String,
}

impl NpassBackend {
    pub fn new(bin: impl Into<PathBuf>, id: impl Into<String>) -> Self {
        Self { bin: bin.into(), id: id.into() }
    }

    /// Executa `npass passkey ARGS` e devolve a saída completa, qualquer que seja o código.
    fn exec(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<std::process::Output, BackendError> {
        let mut cmd = Command::new(&self.bin);
        cmd.arg("passkey").args(args);
        cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() });
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd
            .spawn()
            .map_err(|e| BackendError(format!("não consegui executar {}: {e}", self.bin.display())))?;
        if let (Some(data), Some(mut pipe)) = (stdin, child.stdin.take()) {
            pipe.write_all(data)
                .map_err(|e| BackendError(format!("falha ao escrever no npass: {e}")))?;
        }
        child
            .wait_with_output()
            .map_err(|e| BackendError(format!("falha ao esperar o npass: {e}")))
    }

    fn run(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<Vec<u8>, BackendError> {
        let out = self.exec(args, stdin)?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            return Err(BackendError(if err.is_empty() {
                format!("npass passkey {} falhou ({})", args[0], out.status)
            } else {
                err
            }));
        }
        Ok(out.stdout)
    }
}

/// Linhas `rp<TAB>login<TAB>blob` da saída de `npass passkey list`.
pub fn parse_list(out: &str) -> Vec<Entry> {
    out.lines()
        .filter_map(|l| {
            let mut p = l.split('\t');
            match (p.next(), p.next(), p.next(), p.next()) {
                (Some(rp), Some(login), Some(blob), None) if !rp.is_empty() && !blob.is_empty() => {
                    Some(Entry { rp_id: rp.into(), login: login.into(), blob: blob.into() })
                }
                _ => None,
            }
        })
        .collect()
}

impl Backend for NpassBackend {
    fn list(&self, rp_id: Option<&str>) -> Result<Vec<Entry>, BackendError> {
        let mut args = vec!["list", self.id.as_str()];
        if let Some(rp) = rp_id {
            args.push(rp);
        }
        let out = self.run(&args, None)?;
        Ok(parse_list(&String::from_utf8_lossy(&out)))
    }

    fn load(&self, blob: &str) -> Result<Vec<u8>, BackendError> {
        let out = self.run(&["load", &self.id, blob], None)?;
        let text = String::from_utf8_lossy(&out);
        STANDARD
            .decode(text.trim())
            .map_err(|e| BackendError(format!("credencial base64 inválida em {blob}: {e}")))
    }

    fn store(&self, rp_id: &str, login: &str, credential: &[u8]) -> Result<String, BackendError> {
        let b64 = STANDARD.encode(credential);
        let out = self.run(&["store", &self.id, rp_id, login], Some(b64.as_bytes()))?;
        let name = String::from_utf8_lossy(&out).trim().to_string();
        if name.is_empty() {
            return Err(BackendError("npass passkey store não devolveu o nome do blob".into()));
        }
        Ok(name)
    }

    fn remove(&self, blob: &str) -> Result<(), BackendError> {
        self.run(&["rm", &self.id, blob], None).map(|_| ())
    }

    fn pin_status(&self) -> Result<PinStatus, BackendError> {
        let out = self.run(&["pin", "status", &self.id], None)?;
        parse_pin_status(&String::from_utf8_lossy(&out))
    }

    /// Códigos de `pin verify`: 0 certo, 10 errado, 11 bloqueado, 12 sem PIN.
    fn pin_verify(&self, pin: &str) -> Result<PinCheck, BackendError> {
        let line = format!("{pin}\n");
        let out = self.exec(&["pin", "verify", &self.id], Some(line.as_bytes()))?;
        let left = String::from_utf8_lossy(&out.stdout)
            .lines()
            .find_map(|l| l.strip_prefix("tries-left ").and_then(|v| v.trim().parse::<u8>().ok()))
            .unwrap_or(0);
        match out.status.code() {
            Some(0) => Ok(PinCheck::Ok),
            Some(10) => Ok(PinCheck::Wrong { tries_left: left }),
            Some(11) => Ok(PinCheck::Blocked),
            Some(12) => Ok(PinCheck::NotSet),
            _ => Err(BackendError(String::from_utf8_lossy(&out.stderr).trim().to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_list_aceita_so_linhas_de_3_colunas() {
        let e = parse_list("github.com\tpessoal\t83a1.gpg\nruim\nx\ty\n\ngithub.com\ttrab\t91bc.gpg\n");
        assert_eq!(e.len(), 2);
        assert_eq!(e[1].login, "trab");
        assert_eq!(e[0].blob, "83a1.gpg");
    }

    #[test]
    fn parse_pin_status_le_as_quatro_chaves() {
        let st = parse_pin_status("policy requerido\nset 1\ntries-left 3\nblocked 0\n").unwrap();
        assert_eq!(st, PinStatus { policy: Policy::Requerido, set: true, tries_left: 3, blocked: false });
        assert!(parse_pin_status("policy nunca\n").is_err());
        assert!(parse_pin_status("policy xxx\nset 0\ntries-left 5\nblocked 0\n").is_err());
    }

    #[test]
    fn parse_list_rejeita_colunas_extras() {
        assert!(parse_list("a\tb\tc\td\n").is_empty());
    }
}
