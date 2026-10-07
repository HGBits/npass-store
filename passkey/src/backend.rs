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
}

pub struct NpassBackend {
    bin: PathBuf,
    id: String,
}

impl NpassBackend {
    pub fn new(bin: impl Into<PathBuf>, id: impl Into<String>) -> Self {
        Self { bin: bin.into(), id: id.into() }
    }

    fn run(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<Vec<u8>, BackendError> {
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
        let out = child
            .wait_with_output()
            .map_err(|e| BackendError(format!("falha ao esperar o npass: {e}")))?;
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
    fn parse_list_rejeita_colunas_extras() {
        assert!(parse_list("a\tb\tc\td\n").is_empty());
    }
}
