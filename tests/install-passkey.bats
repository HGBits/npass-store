#!/usr/bin/env bats
# Helpers de extensoes nao sao compilados nem assinados localmente pelo instalador.

setup() {
	[[ "$EUID" -eq 0 ]] || skip "testa instalação global root-owned"
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export PREFIX="$BATS_TEST_TMPDIR/prefix"
	export SOURCE="$BATS_TEST_TMPDIR/source"
	mkdir -p "$SOURCE/passkey"
	cat >"$SOURCE/npass-passkey" <<'EOF'
#!/usr/bin/env bash
echo passkey-nao-deve-rodar
EOF
	chmod 755 "$SOURCE/npass-passkey"
	cat >"$SOURCE/passkey/Cargo.toml" <<'EOF'
[package]
name = "npass-passkeyd"
version = "0.1.0"
EOF
	export CARGO_LOG="$BATS_TEST_TMPDIR/cargo.log"
}

@test "instalador recusa passkey sem assinatura oficial e nao executa cargo" {
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"assinatura ausente/não regular"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-passkey" ]
	[ ! -e "$CARGO_LOG" ]
}

@test "instalador recusa assinatura de teste e nao compila helper" {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$SOURCE/npass-passkey.sig" "$SOURCE/npass-passkey"
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"assinatura inválida"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-passkey" ]
	[ ! -e "$CARGO_LOG" ]
}
