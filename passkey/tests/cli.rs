//! A linha de comando do daemon: não existe modo "aprovar tudo".

use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_npass-passkeyd"))
}

#[test]
fn auto_approve_foi_removido() {
    let o = bin().args(["--id", "x", "--auto-approve"]).output().unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("opção desconhecida"));
}

#[test]
fn a_ajuda_nao_menciona_aprovar_tudo_e_documenta_o_pin() {
    let o = bin().arg("--help").output().unwrap();
    let h = String::from_utf8_lossy(&o.stdout);
    assert!(!h.contains("auto-approve"));
    assert!(h.contains("--pin-cmd") && h.contains("--confirm-cmd"));
}

#[test]
fn protocolo_e_versao() {
    let o = bin().arg("--protocol").output().unwrap();
    assert_eq!(String::from_utf8_lossy(&o.stdout).trim(), "npass-passkeyd-protocol 1");
}
