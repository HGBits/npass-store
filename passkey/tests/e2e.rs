//! Cerimônia WebAuthn completa em processo: makeCredential + getAssertion pelo
//! autenticador real do soft-fido2, com as credenciais indo parar no `Backend`.
//!
//! - sempre: backend em memória (prova a lógica dos callbacks);
//! - com NPASS_E2E_BIN + NPASS_E2E_ID: o backend real (`npass passkey ...` ->
//!   Fido/*.gpg no npass). É o que tests/passkey.bats roda.
//!
//! Só o UHID/navegador ficam de fora (precisam de /dev/uhid e de um browser).

use npass_passkeyd::authenticator_config;
use npass_passkeyd::backend::{Backend, BackendError, Entry, NpassBackend};
use npass_passkeyd::callbacks::NpassCallbacks;
use npass_passkeyd::confirm::Confirm;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use soft_fido2::Authenticator;
use soft_fido2_ctap::cbor::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------- backend em memória

#[derive(Clone, Default)]
struct MemBackend {
    blobs: Arc<Mutex<BTreeMap<String, (String, String, Vec<u8>)>>>,
    n: Arc<Mutex<u32>>,
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

fn make_credential(rp: &str, user_id: &[u8], user: &str, hash: &[u8]) -> Vec<u8> {
    let req = Value::Map(vec![
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
        (int(7), Value::Map(vec![(text("rk"), Value::Bool(true)), (text("uv"), Value::Bool(true))])),
    ]);
    let mut out = vec![0x01];
    out.extend(enc(&req));
    out
}

fn get_assertion(rp: &str, hash: &[u8], allow: Option<&[u8]>) -> Vec<u8> {
    let mut m = vec![(int(1), text(rp)), (int(2), Value::Bytes(hash.to_vec()))];
    if let Some(id) = allow {
        m.push((
            int(3),
            Value::Array(vec![Value::Map(vec![(text("type"), text("public-key")), (text("id"), Value::Bytes(id.to_vec()))])]),
        ));
    }
    m.push((int(5), Value::Map(vec![(text("up"), Value::Bool(true)), (text("uv"), Value::Bool(true))])));
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

fn new_auth<B: Backend + 'static>(b: B) -> Authenticator<NpassCallbacks<B>> {
    Authenticator::with_config(NpassCallbacks::new(b, Confirm::Auto), authenticator_config()).unwrap()
}

/// `fresh` devolve um backend novo apontando para o MESMO armazenamento.
fn ceremony<B: Backend + 'static>(fresh: impl Fn() -> B) {
    let rp = "site.test";
    let mut a = new_auth(fresh());

    // registro
    let h1 = client_hash("webauthn.create", "reg-1");
    let (st, att) = call(&mut a, &make_credential(rp, b"user-1", "ana", &h1));
    assert_eq!(st, 0, "makeCredential: status {st:#04x}");
    let (cred_id, pubkey) = parse_registration(&att);

    // a credencial foi parar no backend, indexada por RP e login
    let listed = fresh().list(Some(rp)).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].login, "ana");
    assert!(fresh().list(Some("outro.test")).unwrap().is_empty());

    // autenticação sem allowList (descoberta pelo RP)
    let h2 = client_hash("webauthn.get", "auth-1");
    let (st, resp) = call(&mut a, &get_assertion(rp, &h2, None));
    assert_eq!(st, 0, "getAssertion: status {st:#04x}");
    check_assertion(&resp, rp, &h2, &pubkey);

    // outro processo (estado volátil vazio): allowList força achar o blob pelo id
    let mut b = new_auth(fresh());
    let h3 = client_hash("webauthn.get", "auth-2");
    let (st, resp) = call(&mut b, &get_assertion(rp, &h3, Some(&cred_id)));
    assert_eq!(st, 0, "getAssertion com allowList: status {st:#04x}");
    check_assertion(&resp, rp, &h3, &pubkey);

    // RP sem credencial: sem credenciais (0x2E)
    let (st, _) = call(&mut b, &get_assertion("nada.test", &h3, None));
    assert_eq!(st, 0x2E, "RP sem passkey deveria dar NoCredentials");

    // segunda conta no mesmo RP: duas passkeys, mesmo RP
    let h4 = client_hash("webauthn.create", "reg-2");
    let (st, att2) = call(&mut b, &make_credential(rp, b"user-2", "beto", &h4));
    assert_eq!(st, 0);
    let (cred_id2, pubkey2) = parse_registration(&att2);
    assert_ne!(cred_id, cred_id2);
    assert_eq!(fresh().list(Some(rp)).unwrap().len(), 2);
    let h5 = client_hash("webauthn.get", "auth-3");
    let mut c = new_auth(fresh());
    let (st, resp) = call(&mut c, &get_assertion(rp, &h5, Some(&cred_id2)));
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
