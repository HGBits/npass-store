//! npass-passkeyd: camada FIDO2/CTAP2 do npass-passkey.
//!
//! Este daemon NÃO tem armazenamento próprio. Cada operação de credencial vira
//! uma chamada a `npass passkey ...` (a extensão `npass-passkey`), que guarda
//! tudo em `Fido/` do npass:
//!
//! ```text
//! navegador -> UHID/CTAPHID -> CTAP2 (soft-fido2) -> callbacks -> npass passkey -> npass
//! ```

pub mod backend;
pub mod callbacks;
pub mod confirm;
#[cfg(target_os = "linux")]
pub mod uhid_loop;

/// Versão do contrato daemon <-> extensão. Tem que ser igual a PASSKEY_PROTO
/// em extensions/npass-passkey; o selo assinado pelo instalador amarra os dois.
pub const PROTOCOL: u32 = 1;

/// AAGUID fixo (16 bytes) deste autenticador.
pub const AAGUID: [u8; 16] = *b"npass-passkeyd-1";

/// Configuração do autenticador, compartilhada pelo daemon e pelos testes.
pub fn authenticator_config() -> soft_fido2::AuthenticatorConfig {
    use soft_fido2::{AuthenticatorConfig, AuthenticatorOptions};
    AuthenticatorConfig::builder()
        .aaguid(AAGUID)
        .max_credentials(1000)
        // ES256: o que o soft-fido2 implementa para chaves de software
        .algorithms(vec![-7])
        .extensions(vec!["credProtect".to_string()])
        .options(
            AuthenticatorOptions::new()
                .with_resident_keys(true)
                .with_user_presence(true)
                .with_user_verification(Some(true))
                .with_client_pin(None)
                .with_pin_uv_auth_token(Some(true))
                .with_make_cred_uv_not_required(Some(true)),
        )
        // sem contador: não regrava o blob a cada login (padrão de passkeys sincronizáveis)
        .constant_sign_count(true)
        .device_name("npass passkey".to_string())
        .vendor_id(0x1209) // pid.codes
        .product_id(0x0001)
        .device_version(0x0100)
        .build()
}
