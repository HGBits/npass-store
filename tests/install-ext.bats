#!/usr/bin/env bats
# install.sh e as extensoes opcionais: por padrao nada acontece; com confirmacao,
# cada extensao e oferecida com descricao e ja vai para o destino final, assinada.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export PREFIX="$BATS_TEST_TMPDIR/prefix"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	unset NPASS_STORE NPASS_GPG NPASS_LANG DESTDIR SUDO_USER NPASS_ENABLE_EXTENSIONS 2>/dev/null || true
}

inst() { "$PROJECT_DIR/install.sh" --prefix="$PREFIX" "$@"; }

# --- por padrao: nada ----------------------------------------------------------

@test "sem terminal e sem flags: instala o npass e nao pergunta nem instala extensao" {
	run bash -c "'$PROJECT_DIR/install.sh' --prefix='$PREFIX' </dev/null"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
	[[ "$output" != *"Extensões opcionais"* ]]
	[ ! -e "$NPASS_EXTENSIONS_DIR" ]
	[ ! -e "$PREFIX/share/npass" ]
}

@test "--no-extensions nunca pergunta, mesmo com respostas disponiveis" {
	run bash -c "printf 's\ns\ns\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-extensions"
	[ "$status" -eq 0 ]
	[[ "$output" != *"Extensões opcionais"* ]]
	[ ! -e "$NPASS_EXTENSIONS_DIR" ]
}

@test "com DESTDIR (empacotamento) nunca pergunta, e --extensions e recusado" {
	run env DESTDIR="$BATS_TEST_TMPDIR/stage" "$PROJECT_DIR/install.sh" --prefix=/usr
	[ "$status" -eq 0 ]
	[[ "$output" != *"Extensões opcionais"* ]]
	[ ! -e "$BATS_TEST_TMPDIR/stage/usr/share/npass" ]
	run env DESTDIR="$BATS_TEST_TMPDIR/stage" "$PROJECT_DIR/install.sh" --prefix=/usr --extensions
	[ "$status" -ne 0 ]
	[[ "$output" == *"DESTDIR"* ]]
}

@test "o PKGBUILD instala sem extensoes (--no-extensions)" {
	grep -q 'install.sh --no-extensions' "$PROJECT_DIR/packaging/PKGBUILD"
}

# --- oferta interativa -----------------------------------------------------------

@test "--extensions mostra a descricao e instala SO o que foi aceito, assinado, no destino final" {
	# respostas: ver extensoes=s, npass-clip-x11=n, npass-import=s
	run bash -c "printf 's\nn\ns\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions --sign-key='$FPR'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"npass-clip-x11 - Copia senha ou campo"* ]]
	[[ "$output" == *"npass-import - Importa senhas de outros gerenciadores"* ]]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-import" ]
	[ -f "$NPASS_EXTENSIONS_DIR/npass-import.sig" ]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-clip-x11" ]
	[ "$(stat -c %a "$NPASS_EXTENSIONS_DIR")" = "700" ]
	[ "$(stat -c %a "$NPASS_EXTENSIONS_DIR/npass-import")" = "755" ]
	# e o ciclo todo funciona: o npass aceita a assinatura e a extensao roda
	NPASS_ENABLE_EXTENSIONS=1 run "$PREFIX/bin/npass" extension list
	[[ "$output" == *"import: ok"* ]]
	NPASS_ENABLE_EXTENSIONS=1 run "$PREFIX/bin/npass" import --list
	[ "$status" -eq 0 ]
	[[ "$output" == *"bitwarden"* ]]
}

@test "o sufixo .bash e removido: npass-clip-x11.bash vira o comando 'clip-x11'" {
	run bash -c "printf 's\ns\nn\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions --sign-key='$FPR'"
	[ "$status" -eq 0 ]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-clip-x11" ]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-clip-x11.bash" ]
	NPASS_ENABLE_EXTENSIONS=1 run "$PREFIX/bin/npass" extension list
	[[ "$output" == *"clip-x11: ok"* ]]
}

@test "recusar no primeiro prompt, responder N ou EOF: nada e instalado" {
	run bash -c "printf 'n\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions"
	[ "$status" -eq 0 ]
	[ ! -e "$NPASS_EXTENSIONS_DIR" ]
	run bash -c "'$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions </dev/null"
	[ "$status" -eq 0 ]
	[ ! -e "$NPASS_EXTENSIONS_DIR" ]
	run bash -c "printf 's\n\n\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions"
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-import" ]
}

@test "extensao ja instalada, identica e assinada: nao refaz" {
	printf 's\nn\ns\n' | inst --extensions --sign-key="$FPR" >/dev/null
	local antes; antes="$(stat -c %i "$NPASS_EXTENSIONS_DIR/npass-import")"
	run bash -c "printf 's\nn\ns\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions --sign-key='$FPR'"
	[[ "$output" == *"já instalada, idêntica e assinada"* ]]
	[ "$(stat -c %i "$NPASS_EXTENSIONS_DIR/npass-import")" = "$antes" ]
}

@test "extensao modificada no destino e substituida pela do repositorio e reassinada" {
	printf 's\nn\ns\n' | inst --extensions --sign-key="$FPR" >/dev/null
	printf '\n# adulterado\n' >>"$NPASS_EXTENSIONS_DIR/npass-import"
	printf 's\nn\ns\n' | inst --extensions --sign-key="$FPR" >/dev/null
	cmp "$PROJECT_DIR/extensions/npass-import" "$NPASS_EXTENSIONS_DIR/npass-import"
	NPASS_ENABLE_EXTENSIONS=1 run "$PREFIX/bin/npass" extension list
	[[ "$output" == *"import: ok"* ]]
}

@test "se a assinatura falhar (sem chave secreta): avisa com o comando exato e deixa o arquivo no lugar" {
	local vazio="$BATS_TEST_TMPDIR/chaveiro-vazio"
	mkdir -m 700 "$vazio"
	run bash -c "printf 's\nn\ns\n' | GNUPGHOME='$vazio' '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions"
	[ "$status" -eq 0 ]
	[[ "$output" == *"NÃO foi possível assinar"* ]]
	[[ "$output" == *"npass extension sign $NPASS_EXTENSIONS_DIR/npass-import"* ]]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-import" ]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-import.sig" ]
}

@test "dependencia ausente e avisada antes de perguntar (xclip para o clip-x11)" {
	command -v xclip >/dev/null && skip "xclip instalado neste sistema"
	run bash -c "printf 's\nn\nn\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions"
	[[ "$output" == *"requer 'xclip'"* ]]
}

# --- --extensions-only -------------------------------------------------------------

@test "--extensions-only sem npass instalado: erro claro e nada feito" {
	run bash -c "printf 's\ns\ns\n' | PATH=/usr/bin:/bin '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions-only"
	if [ "$status" -eq 0 ]; then skip "ha um npass no PATH do sistema"; fi
	[[ "$output" == *"npass não encontrado"* ]]
	[ ! -e "$NPASS_EXTENSIONS_DIR" ]
}

@test "--extensions-only nao reinstala o npass (o pacote do AUR fica intacto) e instala a extensao" {
	inst --no-extensions >/dev/null
	local antes; antes="$(stat -c '%i %Y' "$PREFIX/bin/npass")"
	run bash -c "printf 's\nn\ns\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --extensions-only --sign-key='$FPR'"
	[ "$status" -eq 0 ]
	[[ "$output" != *"Reconstruindo"* ]]
	[ "$(stat -c '%i %Y' "$PREFIX/bin/npass")" = "$antes" ]
	[ -f "$NPASS_EXTENSIONS_DIR/npass-import.sig" ]
}

@test "--uninstall remove so o npass; as extensoes do usuario nao sao tocadas" {
	printf 's\nn\ns\n' | inst --extensions --sign-key="$FPR" >/dev/null
	run inst --uninstall
	[ ! -e "$PREFIX/bin/npass" ]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-import" ]
}
