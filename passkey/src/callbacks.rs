//! Callbacks do autenticador soft-fido2 ligados ao npass.
//!
//! O estado que este módulo guarda é só volátil e NÃO secreto: um mapa
//! credential-id -> nome do blob, para não varrer todos os blobs a cada
//! pedido. Nenhuma credencial fica em memória entre chamadas, e nada vai
//! para disco por aqui.

use crate::backend::{Backend, Entry};
use crate::confirm::Confirm;
use soft_fido2::{
    AuthenticatorCallbacks, Credential, CredentialRef, Error, Result, UpResult, UvResult,
};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Depois de aprovar um RP, UP/UV do mesmo RP dentro desta janela não perguntam de novo
/// (a mesma cerimônia pode pedir UV e depois UP).
const SAME_CEREMONY: Duration = Duration::from_secs(15);
/// Depois de uma varredura completa, id desconhecido não dispara outra varredura por este tempo.
const SCAN_COOLDOWN: Duration = Duration::from_secs(5);

pub struct NpassCallbacks<B: Backend> {
    backend: B,
    confirm: Confirm,
    /// credential id -> blob (volátil, sem segredo)
    index: Mutex<HashMap<Vec<u8>, String>>,
    last_approval: Mutex<Option<(String, Instant)>>,
    last_scan: Mutex<Option<Instant>>,
}

/// Nome da conta como aparece no índice (público): user.name, senão displayName,
/// senão o user handle em hex. Sem caracteres de controle, até 255 bytes.
pub fn login_for(name: Option<&str>, display: Option<&str>, user_id: &[u8]) -> String {
    fn clean(s: &str) -> String {
        let s: String = s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        let mut s = s.trim().to_string();
        while s.len() > 255 {
            s.pop();
        }
        s
    }
    for cand in [name, display].into_iter().flatten() {
        let c = clean(cand);
        if !c.is_empty() {
            return c;
        }
    }
    if user_id.is_empty() {
        "sem-nome".to_string()
    } else {
        let hex: String = user_id.iter().take(32).map(|b| format!("{b:02x}")).collect();
        hex
    }
}

impl<B: Backend> NpassCallbacks<B> {
    pub fn new(backend: B, confirm: Confirm) -> Self {
        Self {
            backend,
            confirm,
            index: Mutex::new(HashMap::new()),
            last_approval: Mutex::new(None),
            last_scan: Mutex::new(None),
        }
    }

    fn approved_recently(&self, rp_id: &str) -> bool {
        matches!(&*self.last_approval.lock().unwrap(),
            Some((rp, at)) if rp == rp_id && at.elapsed() < SAME_CEREMONY)
    }

    fn ask(&self, info: &str, user: Option<&str>, rp_id: &str) -> bool {
        if self.approved_recently(rp_id) {
            return true;
        }
        let ok = self.confirm.ask(info, user, rp_id);
        if ok {
            *self.last_approval.lock().unwrap() = Some((rp_id.to_string(), Instant::now()));
        }
        ok
    }

    /// Carrega e decodifica um blob. Blob rejeitado pelo npass (adulterado, assinatura
    /// inválida, não autorizado) vira `None`: simplesmente não existe como credencial.
    fn load_one(&self, e: &Entry) -> Option<Credential> {
        let bytes = match self.backend.load(&e.blob) {
            Ok(b) => b,
            Err(err) => {
                eprintln!("npass-passkeyd: blob ignorado ({}): {err}", e.blob);
                return None;
            }
        };
        match Credential::from_bytes(&bytes) {
            Ok(c) => {
                self.index.lock().unwrap().insert(c.id.clone(), e.blob.clone());
                Some(c)
            }
            Err(_) => {
                eprintln!("npass-passkeyd: credencial ilegível em {}", e.blob);
                None
            }
        }
    }

    /// Acha a credencial pelo id: mapa volátil primeiro; senão varre os blobs
    /// (o id fica dentro do payload cifrado, então não dá para achar só pelo índice).
    fn resolve(&self, cred_id: &[u8]) -> Option<(Credential, String)> {
        let known = self.index.lock().unwrap().get(cred_id).cloned();
        if let Some(blob) = known {
            let e = Entry { rp_id: String::new(), login: String::new(), blob: blob.clone() };
            match self.load_one(&e) {
                Some(c) if c.id == cred_id => return Some((c, blob)),
                _ => {
                    self.index.lock().unwrap().remove(cred_id);
                }
            }
        }
        if matches!(&*self.last_scan.lock().unwrap(), Some(at) if at.elapsed() < SCAN_COOLDOWN) {
            return None;
        }
        let entries = self.backend.list(None).ok()?;
        let mut found = None;
        for e in &entries {
            if let Some(c) = self.load_one(e) {
                if c.id == cred_id && found.is_none() {
                    found = Some((c, e.blob.clone()));
                }
            }
        }
        *self.last_scan.lock().unwrap() = Some(Instant::now());
        found
    }
}

impl<B: Backend> AuthenticatorCallbacks for NpassCallbacks<B> {
    fn request_up(&self, info: &str, user_name: Option<&str>, rp_id: &str) -> Result<UpResult> {
        Ok(if self.ask(info, user_name, rp_id) { UpResult::Accepted } else { UpResult::Denied })
    }

    /// UV aqui = confirmação explícita do usuário + o pinentry do GPG ao decifrar
    /// (se a chave tiver passphrase e o agent não a tiver em cache). Não há biometria.
    fn request_uv(&self, info: &str, user_name: Option<&str>, rp_id: &str) -> Result<UvResult> {
        Ok(if self.ask(info, user_name, rp_id) { UvResult::AcceptedWithUp } else { UvResult::Denied })
    }

    fn write_credential(&self, cred: &CredentialRef) -> Result<()> {
        let bytes = cred.to_bytes()?;
        let login = login_for(cred.user_name, cred.user_display_name, cred.user_id);
        let previous = self.index.lock().unwrap().get(cred.id).cloned();
        let blob = self.backend.store(cred.rp_id, &login, &bytes).map_err(|e| {
            eprintln!("npass-passkeyd: falha ao guardar a credencial: {e}");
            Error::Other
        })?;
        self.index.lock().unwrap().insert(cred.id.to_vec(), blob.clone());
        // Atualização de uma credencial já guardada: grava o novo, só depois apaga o antigo.
        if let Some(old) = previous {
            if old != blob {
                if let Err(e) = self.backend.remove(&old) {
                    eprintln!("npass-passkeyd: não consegui remover o blob antigo {old}: {e}");
                }
            }
        }
        Ok(())
    }

    fn read_credential(&self, cred_id: &[u8]) -> Result<Option<Credential>> {
        Ok(self.resolve(cred_id).map(|(c, _)| c))
    }

    fn delete_credential(&self, cred_id: &[u8]) -> Result<()> {
        let Some((_, blob)) = self.resolve(cred_id) else {
            return Ok(());
        };
        self.backend.remove(&blob).map_err(|e| {
            eprintln!("npass-passkeyd: falha ao remover {blob}: {e}");
            Error::Other
        })?;
        self.index.lock().unwrap().remove(cred_id);
        Ok(())
    }

    /// Descoberta: o índice restringe ao RP; só esses blobs são abertos.
    /// Mais novas primeiro (a seleção padrão escolhe a primeira).
    fn list_credentials(&self, rp_id: &str, user_id: Option<&[u8]>) -> Result<Vec<Credential>> {
        let entries = self.backend.list(Some(rp_id)).map_err(|e| {
            eprintln!("npass-passkeyd: falha ao listar {rp_id}: {e}");
            Error::Other
        })?;
        let mut out: Vec<Credential> = entries
            .iter()
            .filter_map(|e| self.load_one(e))
            // o índice é só dica: o RP e o user handle vêm da credencial já verificada
            .filter(|c| c.rp.id == rp_id)
            .filter(|c| user_id.map_or(true, |u| c.user.id == u))
            .collect();
        out.sort_by(|a, b| b.created.cmp(&a.created));
        Ok(out)
    }

    fn enumerate_rps(&self) -> Result<Vec<(String, Option<String>, usize)>> {
        let entries = self.backend.list(None).map_err(|_| Error::Other)?;
        let mut counts: Vec<(String, usize)> = Vec::new();
        for e in entries {
            match counts.iter_mut().find(|(rp, _)| *rp == e.rp_id) {
                Some((_, n)) => *n += 1,
                None => counts.push((e.rp_id, 1)),
            }
        }
        Ok(counts.into_iter().map(|(rp, n)| (rp, None, n)).collect())
    }

    fn credential_count(&self) -> Result<usize> {
        Ok(self.backend.list(None).map_err(|_| Error::Other)?.len())
    }

    fn get_timestamp_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_prefere_nome_depois_display_depois_hex() {
        assert_eq!(login_for(Some("ana"), Some("Ana S."), &[1]), "ana");
        assert_eq!(login_for(Some("  "), Some("Ana S."), &[1]), "Ana S.");
        assert_eq!(login_for(None, None, &[0xde, 0xad]), "dead");
        assert_eq!(login_for(None, None, &[]), "sem-nome");
    }

    #[test]
    fn login_sem_controles_e_com_limite() {
        let l = login_for(Some("a\tb\nc"), None, &[]);
        assert_eq!(l, "a b c");
        let longo = "x".repeat(400);
        assert_eq!(login_for(Some(&longo), None, &[]).len(), 255);
    }
}
