#!/usr/bin/env bats
# O daemon passkey precisa vir em pacote de release previamente assinado.

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
	}

@test "instalador recusa passkey sem assinatura oficial e nao executa cargo" {
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"falta o daemon oficial assinado"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-passkey" ]
	}

@test "instalador recusa assinatura de teste e nao compila helper" {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$SOURCE/npass-passkey.sig" "$SOURCE/npass-passkey"
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"falta o daemon oficial assinado"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-passkey" ]
	[ ! -e "$CARGO_LOG" ]
}
