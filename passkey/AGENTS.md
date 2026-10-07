# AGENTS.md - passkey (npass-passkeyd)

Daemon Rust: autenticador FIDO2 virtual. **Sem armazenamento próprio**: toda credencial vai e vem por `npass passkey ...`.

| Arquivo | Papel |
|---|---|
| `src/backend.rs` | trait `Backend` + `NpassBackend` (processo `npass passkey`) |
| `src/callbacks.rs` | callbacks do soft-fido2 -> backend; mapa volátil credId->blob |
| `src/confirm.rs` | presença do usuário (comando, zenity, kdialog, tty; senão nega) |
| `src/uhid_loop.rs` | UHID + CTAPHID + CTAP2 |
| `src/lib.rs` | `PROTOCOL` (tem que igualar `PASSKEY_PROTO` em `extensions/npass-passkey`), AAGUID, config |
| `tests/e2e.rs` | cerimônia WebAuthn em processo (memória; e npass real via `NPASS_E2E_BIN`/`NPASS_E2E_ID`) |

Build: `cargo build --release --locked` (Rust >= 1.91). Mudou o protocolo? Suba `PROTOCOL` e `PASSKEY_PROTO` juntos.
