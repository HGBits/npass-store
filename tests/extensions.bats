#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	export ATACANTE_GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_atacante"
	export ATACANTE_FPR="3B7E950FB71C7B84E52337AFE3A388F60092527E"
	mkdir -p "$NPASS_STORE"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/extensions"
	mkdir -p "$NPASS_EXTENSIONS_DIR"

	# extensao legitima de teste: so ecoa os argumentos recebidos
	cat >"$NPASS_EXTENSIONS_DIR/npass-hello" <<'EOF'
#!/usr/bin/env bash
echo "ola de uma extensao: $*"
EOF
	chmod 755 "$NPASS_EXTENSIONS_DIR/npass-hello"
}

sign_with_own_key() {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$1.sig" "$1"
}

sign_with_attacker_key() {
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --batch --yes --default-key "$ATACANTE_FPR" --detach-sign -o "$1.sig" "$1"
	# importa so a CHAVE PUBLICA do atacante no keyring do usuario -
	# simula ter recebido algo assinado por um terceiro em algum momento
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --export "$ATACANTE_FPR" | gpg --batch --yes --import 2>/dev/null
}

@test "extensoes desligadas por padrao: comando desconhecido continua dando erro de comando desconhecido" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	run "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"comando desconhecido"* ]] || [[ "$output" == *"unknown command"* ]]
}

@test "extensao assinada pela propria chave do usuario executa quando habilitada" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -eq 0 ]
	[[ "$output" == *"ola de uma extensao: mundo"* ]]
}

@test "extensao sem .sig e recusada mesmo habilitada" {
	# sem chamar sign_with_own_key - nao existe npass-hello.sig
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"sem assinatura"* ]] || [[ "$output" == *"no signature"* ]]
}

@test "extensao com arquivo adulterado apos assinar e recusada" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	echo "linha maliciosa adicionada depois de assinar" >> "$NPASS_EXTENSIONS_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"assinatura"* ]] || [[ "$output" == *"signature"* ]]
}

@test "extensao gravavel por outros e recusada mesmo com assinatura valida" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	chmod 757 "$NPASS_EXTENSIONS_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"permiss"* ]] || [[ "$output" == *"writable"* ]]
}

@test "extensao que e um symlink e recusada mesmo apontando para algo assinado" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	mv "$NPASS_EXTENSIONS_DIR/npass-hello" "$NPASS_EXTENSIONS_DIR/real-hello"
	mv "$NPASS_EXTENSIONS_DIR/npass-hello.sig" "$NPASS_EXTENSIONS_DIR/real-hello.sig"
	ln -s "$NPASS_EXTENSIONS_DIR/real-hello" "$NPASS_EXTENSIONS_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"link simbólico"* ]] || [[ "$output" == *"symlink"* ]]
}

@test "extensao assinada por chave que NAO e do usuario e recusada mesmo com assinatura criptograficamente valida" {
	sign_with_attacker_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	# confirma que a assinatura em si e criptograficamente boa antes de
	# testar a recusa - senao o teste podia estar passando pelo motivo errado
	run gpg --batch --verify "$NPASS_EXTENSIONS_DIR/npass-hello.sig" "$NPASS_EXTENSIONS_DIR/npass-hello"
	[ "$status" -eq 0 ]

	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -ne 0 ]
	[[ "$output" == *"não é sua"* ]] || [[ "$output" == *"isn't yours"* ]]
	[[ "$output" == *"$ATACANTE_FPR"* ]]
}

@test "npass extension sign assina um arquivo e a extensao passa a executar" {
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" \
		"$NPASS" extension sign "$NPASS_EXTENSIONS_DIR/npass-hello"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_EXTENSIONS_DIR/npass-hello.sig" ]
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" hello mundo
	[ "$status" -eq 0 ]
	[[ "$output" == *"ola de uma extensao"* ]]
}

@test "npass extension list mostra ok para assinada pela propria chave e recusada para as demais" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	cat >"$NPASS_EXTENSIONS_DIR/npass-semfirma" <<'EOF'
#!/usr/bin/env bash
echo nunca deveria rodar
EOF
	chmod 755 "$NPASS_EXTENSIONS_DIR/npass-semfirma"

	run env NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" "$NPASS" extension list
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello: ok"* ]]
	[[ "$output" == *"semfirma: recusada"* ]]
}

@test "argumentos chegam intactos na extensao, incluindo os com espaco" {
	sign_with_own_key "$NPASS_EXTENSIONS_DIR/npass-hello"
	run env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$NPASS_EXTENSIONS_DIR" \
		"$NPASS" hello "arg com espaco" segundo-arg
	[ "$status" -eq 0 ]
	[[ "$output" == *"arg com espaco segundo-arg"* ]]
}
