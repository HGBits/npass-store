//! Cerimônia WebAuthn completa em processo: makeCredential + getAssertion pelo
//! autenticador real do soft-fido2, com as credenciais indo parar no `Backend`.
//!
//! - sempre: backend em memória (prova a lógica dos callbacks);
//! - com NPASS_E2E_BIN + NPASS_E2E_ID: o backend real (`npass passkey ...` ->
//!   Fido/*.gpg no npass). É o que tests/passkey.bats roda.
//!
//! Só o UHID/navegador ficam de fora (precisam de /dev/uhid e de um browser).

use npass_passkeyd::authenticator_config;
use npass_passkeyd::backend::{Backend, BackendError, Entry, NpassBackend, PinCheck, PinStatus, Policy};
use npass_passkeyd::callbacks::NpassCallbacks;
use npass_passkeyd::confirm::Confirm;
use npass_passkeyd::pin::PinPrompt;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use soft_fido2::Authenticator;
use soft_fido2_ctap::cbor::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------- backend em memória

/// Modelo em memória do que o `npass passkey pin` faz (5 erros bloqueiam).
struct MemPin {
    policy: Policy,
    pin: Option<String>,
    errors: u8,
}

#[derive(Clone)]
struct MemBackend {
    blobs: Arc<Mutex<BTreeMap<String, (String, String, Vec<u8>)>>>,
    n: Arc<Mutex<u32>>,
    pin: Arc<Mutex<MemPin>>,
}

impl Default for MemBackend {
    fn default() -> Self {
        Self {
            blobs: Default::default(),
            n: Default::default(),
            pin: Arc::new(Mutex::new(MemPin { policy: Policy::Opcional, pin: None, errors: 0 })),
        }
    }
}

impl MemBackend {
    fn with_pin(policy: Policy, pin: Option<&str>) -> Self {
        let b = Self::default();
        *b.pin.lock().unwrap() = MemPin { policy, pin: pin.map(String::from), errors: 0 };
        b
    }
}

impl Backend for MemBackend {
    fn list(&self, rp: Option<&str>) -> Result<Vec<Entry>, BackendError> {
        Ok(self
            .blobs
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, (r, _, _))| rp.is_none_or(|x| x == r))
            .map(|(b, (r, l, _))| Entry { rp_id: r.clone(), login: l.clone(), blob: b.clone() })
            .collect())
    }
    fn load(&self, blob: &str) -> Result<Vec<u8>, BackendError> {
        self.blobs
            .lock()
            .unwrap()
            .get(blob)
            .map(|(_, _, c)| c.clone())
            .ok_or_else(|| BackendError("sem blob".into()))
    }
    fn store(&self, rp: &str, login: &str, cred: &[u8]) -> Result<String, BackendError> {
        let mut n = self.n.lock().unwrap();
        *n += 1;
        let name = format!("blob{n}.gpg");
        self.blobs.lock().unwrap().insert(name.clone(), (rp.into(), login.into(), cred.to_vec()));
        Ok(name)
    }
    fn remove(&self, blob: &str) -> Result<(), BackendError> {
        self.blobs.lock().unwrap().remove(blob);
        Ok(())
    }
    fn pin_status(&self) -> Result<PinStatus, BackendError> {
        let p = self.pin.lock().unwrap();
        Ok(PinStatus { policy: p.policy, set: p.pin.is_some(), tries_left: 5 - p.errors, blocked: p.errors >= 5 })
    }
    fn pin_verify(&self, pin: &str) -> Result<PinCheck, BackendError> {
        let mut p = self.pin.lock().unwrap();
        let Some(real) = p.pin.clone() else { return Ok(PinCheck::NotSet) };
        if p.errors >= 5 {
            return Ok(PinCheck::Blocked);
        }
        if real == pin {
            p.errors = 0;
            return Ok(PinCheck::Ok);
        }
        p.errors += 1;
        Ok(PinCheck::Wrong { tries_left: 5 - p.errors })
    }
}

// ---------------------------------------------------------------- CBOR helpers

fn enc(v: &Value) -> Vec<u8> {
    let mut b = Vec::new();
    soft_fido2_ctap::cbor::into_writer(v, &mut b).unwrap();
    b
}
fn int(n: i128) -> Value { Value::Integer(n) }
fn text(s: &str) -> Value { Value::Text(s.into()) }
fn get<'a>(m: &'a Value, key: i128) -> &'a Value {
    let Value::Map(kv) = m else { panic!("não é mapa") };
    &kv.iter().find(|(k, _)| *k == Value::Integer(key)).unwrap_or_else(|| panic!("falta a chave {key}")).1
}
fn bytes(v: &Value) -> Vec<u8> {
    let Value::Bytes(b) = v else { panic!("não é bytes") };
    b.clone()
}
fn client_hash(kind: &str, challenge: &str) -> Vec<u8> {
    Sha256::digest(format!(r#"{{"type":"{kind}","challenge":"{challenge}","origin":"https://site.test"}}"#)).to_vec()
}

fn make_credential(rp: &str, user_id: &[u8], user: &str, hash: &[u8], uv: bool, cp_optional: bool) -> Vec<u8> {
    let mut req = vec![
        (int(1), Value::Bytes(hash.to_vec())),
        (int(2), Value::Map(vec![(text("id"), text(rp)), (text("name"), text(rp))])),
        (
            int(3),
            Value::Map(vec![
                (text("id"), Value::Bytes(user_id.to_vec())),
                (text("name"), text(user)),
                (text("displayName"), text(user)),
            ]),
        ),
        (int(4), Value::Array(vec![Value::Map(vec![(text("type"), text("public-key")), (text("alg"), int(-7))])])),
        (int(7), {
            let mut o = vec![(text("rk"), Value::Bool(true))];
            if uv {
                o.push((text("uv"), Value::Bool(true)));
            }
            Value::Map(o)
        }),
    ];
    if cp_optional {
        // credProtect nível 1: o site aceita usar a credencial só com presença
        req.push((int(6), Value::Map(vec![(text("credProtect"), int(1))])));
    }
    let req = Value::Map(req);
    let mut out = vec![0x01];
    out.extend(enc(&req));
    out
}

fn get_assertion(rp: &str, hash: &[u8], allow: Option<&[u8]>, uv: bool) -> Vec<u8> {
    let mut m = vec![(int(1), text(rp)), (int(2), Value::Bytes(hash.to_vec()))];
    if let Some(id) = allow {
        m.push((
            int(3),
            Value::Array(vec![Value::Map(vec![(text("type"), text("public-key")), (text("id"), Value::Bytes(id.to_vec()))])]),
        ));
    }
    let mut o = vec![(text("up"), Value::Bool(true))];
    if uv {
        o.push((text("uv"), Value::Bool(true)));
    }
    m.push((int(5), Value::Map(o)));
    let mut out = vec![0x02];
    out.extend(enc(&Value::Map(m)));
    out
}

fn call<C: soft_fido2::AuthenticatorCallbacks + 'static>(a: &mut Authenticator<C>, req: &[u8]) -> (u8, Value) {
    let mut resp = Vec::new();
    a.handle(req, &mut resp).unwrap();
    let status = resp[0];
    let v = if resp.len() > 1 { soft_fido2_ctap::cbor::decode(&resp[1..]).unwrap() } else { Value::Null };
    (status, v)
}

/// credId + chave pública SEC1 (0x04||x||y) a partir do authData do attestation.
fn parse_registration(att: &Value) -> (Vec<u8>, Vec<u8>) {
    let ad = bytes(get(att, 2));
    let len = u16::from_be_bytes([ad[53], ad[54]]) as usize;
    let cred_id = ad[55..55 + len].to_vec();
    let cose: Value = soft_fido2_ctap::cbor::decode(&ad[55 + len..]).unwrap();
    let Value::Map(kv) = &cose else { panic!() };
    let coord = |k: i128| bytes(&kv.iter().find(|(a, _)| *a == Value::Integer(k)).unwrap().1);
    let mut sec1 = vec![0x04];
    sec1.extend(coord(-2));
    sec1.extend(coord(-3));
    (cred_id, sec1)
}

fn check_assertion(resp: &Value, rp: &str, hash: &[u8], pubkey: &[u8]) {
    let ad = bytes(get(resp, 2));
    assert_eq!(&ad[..32], Sha256::digest(rp.as_bytes()).as_slice(), "rpIdHash");
    assert!(ad[32] & 0x01 != 0, "UP");
    let sig = Signature::from_der(&bytes(get(resp, 3))).expect("assinatura DER");
    let mut signed = ad.clone();
    signed.extend_from_slice(hash);
    VerifyingKey::from_sec1_bytes(pubkey).unwrap().verify(&signed, &sig).expect("assinatura ES256 válida");
}

// ---------------------------------------------------------------- a cerimônia

/// Confirmação sempre "sim" (comando `true`) e PIN vindo de `pin_cmd`.
fn new_auth_pin<B: Backend + 'static>(b: B, pin_cmd: &str) -> Authenticator<NpassCallbacks<B>> {
    let cb = NpassCallbacks::new(b, Confirm::Shell("true".into()), PinPrompt::Shell(pin_cmd.into()));
    Authenticator::with_config(cb, authenticator_config()).unwrap()
}

fn new_auth<B: Backend + 'static>(b: B) -> Authenticator<NpassCallbacks<B>> {
    new_auth_pin(b, "false") // sem PIN definido ninguém pergunta; se perguntasse, falharia
}

/// `fresh` devolve um backend novo apontando para o MESMO armazenamento.
fn ceremony<B: Backend + 'static>(fresh: impl Fn() -> B) {
    let rp = "site.test";
    let mut a = new_auth(fresh());

    // registro
    let h1 = client_hash("webauthn.create", "reg-1");
    let (st, att) = call(&mut a, &make_credential(rp, b"user-1", "ana", &h1, true, false));
    assert_eq!(st, 0, "makeCredential: status {st:#04x}");
    let (cred_id, pubkey) = parse_registration(&att);

    // a credencial foi parar no backend, indexada por RP e login
    let listed = fresh().list(Some(rp)).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].login, "ana");
    assert!(fresh().list(Some("outro.test")).unwrap().is_empty());

    // autenticação sem allowList (descoberta pelo RP)
    let h2 = client_hash("webauthn.get", "auth-1");
    let (st, resp) = call(&mut a, &get_assertion(rp, &h2, None, true));
    assert_eq!(st, 0, "getAssertion: status {st:#04x}");
    check_assertion(&resp, rp, &h2, &pubkey);

    // outro processo (estado volátil vazio): allowList força achar o blob pelo id
    let mut b = new_auth(fresh());
    let h3 = client_hash("webauthn.get", "auth-2");
    let (st, resp) = call(&mut b, &get_assertion(rp, &h3, Some(&cred_id), true));
    assert_eq!(st, 0, "getAssertion com allowList: status {st:#04x}");
    check_assertion(&resp, rp, &h3, &pubkey);

    // RP sem credencial: sem credenciais (0x2E)
    let (st, _) = call(&mut b, &get_assertion("nada.test", &h3, None, true));
    assert_eq!(st, 0x2E, "RP sem passkey deveria dar NoCredentials");

    // segunda conta no mesmo RP: duas passkeys, mesmo RP
    let h4 = client_hash("webauthn.create", "reg-2");
    let (st, att2) = call(&mut b, &make_credential(rp, b"user-2", "beto", &h4, true, false));
    assert_eq!(st, 0);
    let (cred_id2, pubkey2) = parse_registration(&att2);
    assert_ne!(cred_id, cred_id2);
    assert_eq!(fresh().list(Some(rp)).unwrap().len(), 2);
    let h5 = client_hash("webauthn.get", "auth-3");
    let mut c = new_auth(fresh());
    let (st, resp) = call(&mut c, &get_assertion(rp, &h5, Some(&cred_id2), true));
    assert_eq!(st, 0);
    check_assertion(&resp, rp, &h5, &pubkey2);
}

#[test]
fn cerimonia_completa_com_backend_em_memoria() {
    let mem = MemBackend::default();
    ceremony(|| mem.clone());
}

#[test]
fn cerimonia_completa_com_o_npass_real() {
    let (Ok(bin), Ok(id)) = (std::env::var("NPASS_E2E_BIN"), std::env::var("NPASS_E2E_ID")) else {
        eprintln!("NPASS_E2E_BIN/NPASS_E2E_ID ausentes: pulando o backend real");
        return;
    };
    ceremony(|| NpassBackend::new(bin.clone(), id.clone()));
}


// ---------------------------------------------------------------- PIN e política

fn reg<B: Backend + 'static>(a: &mut Authenticator<NpassCallbacks<B>>, rp: &str, uv: bool) -> u8 {
    reg_id(a, rp, uv).0
}

/// status + credential id (vazio se falhou)
fn reg_id<B: Backend + 'static>(a: &mut Authenticator<NpassCallbacks<B>>, rp: &str, uv: bool) -> (u8, Vec<u8>) {
    reg_id_cp(a, rp, uv, false)
}

fn reg_id_cp<B: Backend + 'static>(a: &mut Authenticator<NpassCallbacks<B>>, rp: &str, uv: bool, cp_optional: bool) -> (u8, Vec<u8>) {
    let h = client_hash("webauthn.create", "pin");
    let (st, att) = call(a, &make_credential(rp, b"u", "ana", &h, uv, cp_optional));
    (st, if st == 0 { parse_registration(&att).0 } else { vec![] })
}

#[test]
fn politica_nunca_ignora_o_pin_mesmo_definido() {
    let b = MemBackend::with_pin(Policy::Nunca, Some("Abc123"));
    let mut a = new_auth_pin(b.clone(), "false");
    assert_eq!(reg(&mut a, "n1.test", true), 0);
    assert_eq!(reg(&mut a, "n2.test", false), 0);
    assert_eq!(b.pin_status().unwrap().tries_left, 5);
}

/// Autentica com allowList (é como os sites chamam quando já sabem o id; a biblioteca só
/// divulga passkey descobrível sem UV se a credencial permitir).
fn asrt<B: Backend + 'static>(a: &mut Authenticator<NpassCallbacks<B>>, rp: &str, id: &[u8], uv: bool) -> u8 {
    let h = client_hash("webauthn.get", "pin");
    call(a, &get_assertion(rp, &h, Some(id), uv)).0
}

#[test]
fn politica_opcional_so_pede_pin_em_uv_e_se_houver_pin() {
    // Com PIN definido. Criar passkey descobrível é sempre com verificação do usuário
    // (autenticador com UV embutido, CTAP2 §6.1.2), então o registro pede o PIN.
    let b = MemBackend::with_pin(Policy::Opcional, Some("Abc123"));
    assert_ne!(reg(&mut new_auth_pin(b.clone(), "false"), "o1.test", true), 0, "registro sem PIN digitado");
    assert_ne!(reg(&mut new_auth_pin(b.clone(), "echo Errado9"), "o1.test", true), 0, "registro com PIN errado");
    // o site pede credProtect nível 1 (usável só com presença)
    let (st, id) = reg_id_cp(&mut new_auth_pin(b.clone(), "echo Abc123"), "o1.test", true, true);
    assert_eq!(st, 0, "registro com PIN certo");
    // autenticar: só presença (site não pede UV) NÃO pede PIN; com UV pede
    assert_eq!(asrt(&mut new_auth_pin(b.clone(), "false"), "o1.test", &id, false), 0, "UP sem PIN");
    assert_ne!(asrt(&mut new_auth_pin(b.clone(), "false"), "o1.test", &id, true), 0, "UV sem PIN digitado");
    assert_ne!(asrt(&mut new_auth_pin(b.clone(), "echo Errado9"), "o1.test", &id, true), 0, "UV com PIN errado");
    assert_eq!(asrt(&mut new_auth_pin(b.clone(), "echo Abc123"), "o1.test", &id, true), 0, "UV com PIN certo");
    // sem PIN definido: só a confirmação, mesmo com UV
    let b = MemBackend::with_pin(Policy::Opcional, None);
    let (st, id) = reg_id(&mut new_auth_pin(b.clone(), "false"), "o5.test", true);
    assert_eq!(st, 0);
    assert_eq!(asrt(&mut new_auth_pin(b, "false"), "o5.test", &id, true), 0);
}

#[test]
fn politica_requerido_exige_pin_em_toda_operacao_e_nega_sem_pin() {
    let b = MemBackend::with_pin(Policy::Requerido, Some("Abc123"));
    assert_ne!(reg(&mut new_auth_pin(b.clone(), "false"), "r1.test", false), 0, "UP sem PIN");
    assert_ne!(reg(&mut new_auth_pin(b.clone(), "echo Errado9"), "r2.test", false), 0);
    assert_eq!(reg(&mut new_auth_pin(b.clone(), "echo Abc123"), "r3.test", false), 0, "UP com PIN certo");
    let (st, id) = reg_id_cp(&mut new_auth_pin(b.clone(), "echo Abc123"), "r4.test", true, true);
    assert_eq!(st, 0, "UV com PIN certo");
    // até a autenticação só com presença (sem UV do site) exige o PIN
    assert_ne!(asrt(&mut new_auth_pin(b.clone(), "false"), "r4.test", &id, false), 0, "UP sem PIN");
    assert_eq!(asrt(&mut new_auth_pin(b.clone(), "echo Abc123"), "r4.test", &id, false), 0, "UP com PIN certo");
    // requerido e nenhum PIN definido: nega tudo, mesmo com "PIN" disponível
    let vazio = MemBackend::with_pin(Policy::Requerido, None);
    assert_ne!(reg(&mut new_auth_pin(vazio.clone(), "echo Abc123"), "r5.test", true), 0);
    assert!(vazio.list(None).unwrap().is_empty(), "nada pode ter sido guardado");
}

#[test]
fn cinco_erros_bloqueiam_e_nem_o_pin_certo_passa() {
    let b = MemBackend::with_pin(Policy::Requerido, Some("Abc123"));
    for i in 0..5 {
        assert_ne!(reg(&mut new_auth_pin(b.clone(), "echo Errado9"), &format!("b{i}.test"), true), 0);
    }
    let st = b.pin_status().unwrap();
    assert!(st.blocked && st.tries_left == 0);
    assert_ne!(reg(&mut new_auth_pin(b.clone(), "echo Abc123"), "b9.test", true), 0, "bloqueado");
    assert!(b.list(None).unwrap().is_empty());
}

#[test]
fn acerto_zera_o_contador_de_erros() {
    let b = MemBackend::with_pin(Policy::Requerido, Some("Abc123"));
    for i in 0..4 {
        assert_ne!(reg(&mut new_auth_pin(b.clone(), "echo Errado9"), &format!("z{i}.test"), true), 0);
    }
    assert_eq!(reg(&mut new_auth_pin(b.clone(), "echo Abc123"), "z9.test", true), 0);
    assert_eq!(b.pin_status().unwrap().tries_left, 5);
}

// ---- com o npass real: política, 5 erros, troca de PIN e desbloqueio com a chave GPG

fn cli(bin: &str, id: &str, script: &str, pins: &[(&str, &str)]) -> (i32, String) {
    let mut c = std::process::Command::new("bash");
    c.arg("-c").arg(format!("\"$B\" passkey {script}")).env("B", bin).env("ID", id);
    for (k, v) in pins {
        c.env(k, v);
    }
    let o = c.output().unwrap();
    (o.status.code().unwrap_or(-1), String::from_utf8_lossy(&o.stdout).to_string() + &String::from_utf8_lossy(&o.stderr))
}

#[test]
fn pin_com_o_npass_real() {
    let (Ok(bin), Ok(id)) = (std::env::var("NPASS_E2E_BIN"), std::env::var("NPASS_E2E_PIN_ID")) else {
        eprintln!("NPASS_E2E_BIN/NPASS_E2E_PIN_ID ausentes: pulando o PIN real");
        return;
    };
    let real = || NpassBackend::new(bin.clone(), id.clone());
    let ok = |c: (i32, String)| assert_eq!(c.0, 0, "{}", c.1);

    ok(cli(&bin, &id, r#"pin set "$ID" --new-pin-fd 3 3<<<"$P1""#, &[("P1", "Abc12345")]));
    ok(cli(&bin, &id, r#"pin policy "$ID" requerido --pin-fd 3 3<<<"$P1""#, &[("P1", "Abc12345")]));
    assert_eq!(real().pin_status().unwrap().policy, Policy::Requerido);

    // sem PIN digitado: nega; com PIN certo: registra
    assert_ne!(reg(&mut new_auth_pin(real(), "false"), "p0.test", false), 0);
    assert_eq!(reg(&mut new_auth_pin(real(), "echo Abc12345"), "p1.test", false), 0);
    assert_eq!(real().list(Some("p1.test")).unwrap().len(), 1);

    // 5 erros bloqueiam; depois nem o certo passa
    for i in 0..5 {
        assert_ne!(reg(&mut new_auth_pin(real(), "echo Errado99"), &format!("pe{i}.test"), false), 0);
    }
    assert!(real().pin_status().unwrap().blocked);
    assert_ne!(reg(&mut new_auth_pin(real(), "echo Abc12345"), "p2.test", false), 0);
    assert!(real().list(Some("p2.test")).unwrap().is_empty());

    // troca exigindo o PIN atual: bloqueado não serve; a chave GPG (--gpg) desbloqueia e troca
    assert_ne!(cli(&bin, &id, r#"pin change "$ID" --pin-fd 3 --new-pin-fd 4 3<<<"$P1" 4<<<"$P2""#, &[("P1", "Abc12345"), ("P2", "Novo98765")]).0, 0);
    ok(cli(&bin, &id, r#"pin change "$ID" --gpg --new-pin-fd 4 4<<<"$P2""#, &[("P2", "Novo98765")]));
    assert!(!real().pin_status().unwrap().blocked);
    assert_ne!(reg(&mut new_auth_pin(real(), "echo Abc12345"), "p3.test", false), 0, "PIN antigo");
    assert_eq!(reg(&mut new_auth_pin(real(), "echo Novo98765"), "p4.test", false), 0, "PIN novo");

    // troca com o PIN atual
    ok(cli(&bin, &id, r#"pin change "$ID" --pin-fd 3 --new-pin-fd 4 3<<<"$P1" 4<<<"$P2""#, &[("P1", "Novo98765"), ("P2", "Terceiro77")]));
    assert_eq!(reg(&mut new_auth_pin(real(), "echo Terceiro77"), "p5.test", false), 0);

    // política nunca: o PIN deixa de ser pedido
    ok(cli(&bin, &id, r#"pin policy "$ID" nunca --pin-fd 3 3<<<"$P1""#, &[("P1", "Terceiro77")]));
    assert_eq!(reg(&mut new_auth_pin(real(), "false"), "p6.test", true), 0);
}
