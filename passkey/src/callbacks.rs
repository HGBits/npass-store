//! Callbacks do autenticador soft-fido2 ligados ao npass.
//!
//! O estado que este módulo guarda é só volátil e NÃO secreto: um mapa
//! credential-id -> nome do blob, para não varrer todos os blobs a cada
//! pedido. Nenhuma credencial fica em memória entre chamadas, e nada vai
//! para disco por aqui.

use crate::backend::{Backend, Entry, PinCheck, Policy};
use crate::confirm::Confirm;
use crate::pin::PinPrompt;
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

/// Qual callback pediu a autorização: só presença (UP) ou verificação do usuário (UV).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Up,
    Uv,
}

/// A política manda: quando esta operação exige PIN.
///  - nunca: jamais; opcional: só em UV e se houver PIN; requerido: sempre (UP e UV).
pub fn needs_pin(policy: Policy, kind: Kind, pin_set: bool) -> bool {
    match (policy, kind) {
        (Policy::Nunca, _) => false,
        (Policy::Opcional, Kind::Uv) => pin_set,
        (Policy::Opcional, Kind::Up) => false,
        (Policy::Requerido, _) => true,
    }
}

/// Aviso ao usuário: stderr e, se existir, notify-send.
fn notify(msg: &str) {
    eprintln!("npass-passkeyd: {msg}");
    let _ = std::process::Command::new("notify-send")
        .args(["npass passkey", msg])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

pub struct NpassCallbacks<B: Backend> {
    backend: B,
    confirm: Confirm,
    pin: PinPrompt,
    /// credential id -> blob (volátil, sem segredo)
    index: Mutex<HashMap<Vec<u8>, String>>,
    /// (rp, quando, foi com PIN?)
    last_approval: Mutex<Option<(String, Instant, bool)>>,
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
    pub fn new(backend: B, confirm: Confirm, pin: PinPrompt) -> Self {
        Self {
            backend,
            confirm,
            pin,
            index: Mutex::new(HashMap::new()),
            last_approval: Mutex::new(None),
            last_scan: Mutex::new(None),
        }
    }

    fn approved_recently(&self, rp_id: &str, with_pin: bool) -> bool {
        matches!(&*self.last_approval.lock().unwrap(),
            Some((rp, at, pin)) if rp == rp_id && at.elapsed() < SAME_CEREMONY && (*pin || !with_pin))
    }

    fn remember(&self, rp_id: &str, with_pin: bool) {
        *self.last_approval.lock().unwrap() = Some((rp_id.to_string(), Instant::now(), with_pin));
    }

    /// Decide UP/UV conforme a política de PIN da identidade. Qualquer dúvida = nega.
    fn authorize(&self, kind: Kind, info: &str, user: Option<&str>, rp_id: &str) -> bool {
        // PIN já digitado para este RP na mesma cerimônia vale para UV e UP seguidos.
        if self.approved_recently(rp_id, true) {
            return true;
        }
        let st = match self.backend.pin_status() {
            Ok(st) => st,
            Err(e) => {
                notify(&format!("não consegui ler a política de PIN; negado ({rp_id}): {e}"));
                return false;
            }
        };
        if st.blocked {
            notify("PIN bloqueado após 5 erros; negado. Desbloqueie com: npass passkey pin change ID --gpg");
            return false;
        }
        if !needs_pin(st.policy, kind, st.set) {
            if self.approved_recently(rp_id, false) {
                return true;
            }
            let ok = self.confirm.ask(info, user, rp_id);
            if ok {
                self.remember(rp_id, false);
            }
            return ok;
        }
        if !st.set {
            notify("política 'requerido' sem PIN definido; negado. Defina com: npass passkey pin set ID");
            return false;
        }
        let Some(pin) = self.pin.ask(rp_id, user, st.tries_left) else {
            return false;
        };
        match self.backend.pin_verify(pin.as_str()) {
            Ok(PinCheck::Ok) => {
                self.remember(rp_id, true);
                true
            }
            Ok(PinCheck::Wrong { tries_left: 0 }) | Ok(PinCheck::Blocked) => {
                notify("PIN incorreto; BLOQUEADO. Desbloqueie com: npass passkey pin change ID --gpg");
                false
            }
            Ok(PinCheck::Wrong { tries_left }) => {
                notify(&format!("PIN incorreto; restam {tries_left} tentativa(s)"));
                false
            }
            Ok(PinCheck::NotSet) => {
                notify("não há PIN definido; negado");
                false
            }
            Err(e) => {
                notify(&format!("falha ao conferir o PIN; negado: {e}"));
                false
            }
        }
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
        Ok(if self.authorize(Kind::Up, info, user_name, rp_id) { UpResult::Accepted } else { UpResult::Denied })
    }

    /// UV = PIN conferido (se a política pedir) ou confirmação explícita, mais o pinentry do
    /// GPG ao decifrar (se a chave tiver passphrase e o agent não a tiver em cache).
    /// Não há biometria.
    fn request_uv(&self, info: &str, user_name: Option<&str>, rp_id: &str) -> Result<UvResult> {
        Ok(if self.authorize(Kind::Uv, info, user_name, rp_id) { UvResult::AcceptedWithUp } else { UvResult::Denied })
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
    fn politica_decide_quando_pedir_pin() {
        use Kind::*;
        use Policy::*;
        // nunca: jamais
        assert!(!needs_pin(Nunca, Up, true) && !needs_pin(Nunca, Uv, true));
        // opcional: só UV e só se houver PIN
        assert!(!needs_pin(Opcional, Up, true));
        assert!(needs_pin(Opcional, Uv, true));
        assert!(!needs_pin(Opcional, Uv, false));
        // requerido: sempre, haja PIN ou não (sem PIN, authorize nega)
        assert!(needs_pin(Requerido, Up, false) && needs_pin(Requerido, Uv, true));
    }

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
