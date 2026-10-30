#!/usr/bin/env bats

setup() {
	[[ "$EUID" -eq 0 ]] || skip "testa a fronteira root-owned; requer root"
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
	export XDG_DATA_DIRS="$BATS_TEST_TMPDIR/share"
	export NPASS_TEST_EXT_DIR="$XDG_DATA_DIRS/npass/extensions"
	export NPASS_TEST_KEY="$XDG_DATA_DIRS/npass/extension-signing-key.asc"
	mkdir -p "$NPASS_TEST_EXT_DIR"
	gpg --batch --export "$FPR" >"$NPASS_TEST_KEY"
	chmod 644 "$NPASS_TEST_KEY"
	cat >"$NPASS_TEST_EXT_DIR/npass-hello" <<'EOF'
#!/usr/bin/env bash
echo "ola de uma extensao: $*"
EOF
	chmod 755 "$NPASS_TEST_EXT_DIR/npass-hello"
}

sign_with_official_test_key() {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$1.sig" "$1"
}

sign_with_attacker_key() {
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --batch --yes --default-key "$ATACANTE_FPR" --detach-sign -o "$1.sig" "$1"
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --export "$ATACANTE_FPR" | gpg --batch --yes --import 2>/dev/null
}

@test "extensao oficial executa sem opt-in e ignora variaveis antigas de controle" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=0 NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/atacante" "$NPASS" hello mundo
	[ "$status" -eq 0 ]
	[[ "$output" == *"ola de uma extensao: mundo"* ]]
}

@test "extensao sem assinatura oficial e recusada" {
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"sem assinatura oficial"* ]]
}

@test "extensao adulterada depois da assinatura e recusada" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	echo "linha maliciosa" >>"$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"assinatura"* ]]
}

@test "extensao gravavel por grupo ou outros e recusada" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	chmod 757 "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"permissões inseguras"* ]]
}

@test "executavel com setuid e recusado" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	chmod 4755 "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"permissões inseguras"* ]]
}

@test "diretorio XDG controlado por usuario e recusado" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	chown 65534 "$XDG_DATA_DIRS"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"permissões inseguras"* ]]
}

@test "arquivo de extensao que nao pertence ao root e recusado" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	chown 65534 "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"permissões inseguras"* ]]
}

@test "extensao que e symlink e recusada" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	mv "$NPASS_TEST_EXT_DIR/npass-hello" "$NPASS_TEST_EXT_DIR/real-hello"
	mv "$NPASS_TEST_EXT_DIR/npass-hello.sig" "$NPASS_TEST_EXT_DIR/real-hello.sig"
	ln -s "$NPASS_TEST_EXT_DIR/real-hello" "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"link simbólico"* ]]
}

@test "assinatura de chave externa e recusada mesmo com a chave publica no keyring do usuario" {
	sign_with_attacker_key "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"assinatura"* ]]
}

@test "extension sign foi removido e nao pode autorizar executaveis" {
	run "$NPASS" extension sign "$NPASS_TEST_EXT_DIR/npass-hello"
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso: npass extension list"* ]]
	[ ! -e "$NPASS_TEST_EXT_DIR/npass-hello.sig" ]
}

@test "extension list mostra estado de confianca sem executar extensoes" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	cat >"$NPASS_TEST_EXT_DIR/npass-sem-firma" <<'EOF'
#!/usr/bin/env bash
echo nunca deveria rodar
EOF
	chmod 755 "$NPASS_TEST_EXT_DIR/npass-sem-firma"
	run "$NPASS" extension list
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello: ok"* ]]
	[[ "$output" == *"sem-firma: recusada"* ]]
}

@test "argumentos chegam intactos incluindo espacos" {
	sign_with_official_test_key "$NPASS_TEST_EXT_DIR/npass-hello"
	run "$NPASS" hello "arg com espaco" segundo-arg
	[ "$status" -eq 0 ]
	[[ "$output" == *"arg com espaco segundo-arg"* ]]
}

@test "nome de extensao nao permite caminho ou traversal" {
	run "$NPASS" ../hello
	[ "$status" -ne 0 ]
	[[ "$output" == *"comando desconhecido"* ]]
}
