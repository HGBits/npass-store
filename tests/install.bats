#!/usr/bin/env bats

setup() {
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export PREFIX="$BATS_TEST_TMPDIR/prefix"
	export DESTDIR=""
	unset NPASS_STORE NPASS_GPG NPASS_LANG 2>/dev/null || true
}

@test "instala binario e man page em PREFIX/bin e PREFIX/share/man/man1" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
	[ -f "$PREFIX/share/man/man1/npass.1" ]
}

@test "binario instalado executa e responde ao help" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	run "$PREFIX/bin/npass" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"npass"* ]]
}

@test "permissoes: binario 755, man page 644" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	run stat -c '%a' "$PREFIX/bin/npass"
	[ "$output" = "755" ]
	run stat -c '%a' "$PREFIX/share/man/man1/npass.1"
	[ "$output" = "644" ]
}

@test "instalar duas vezes seguidas nao falha (idempotente)" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
}

@test "--uninstall remove exatamente o que foi instalado" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass" ]
	[ ! -e "$PREFIX/share/man/man1/npass.1" ]
}

@test "--uninstall sem nada instalado nao falha, so avisa" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --uninstall
	[ "$status" -eq 0 ]
	[[ "$output" == *"nada instalado"* ]]
}

@test "--prefix=PATH funciona igual a variavel de ambiente PREFIX" {
	run "$PROJECT_DIR/install.sh" "--prefix=$PREFIX"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
}

@test "DESTDIR + PREFIX (empacotamento) instala dentro do staging, nao no sistema real" {
	local destdir="$BATS_TEST_TMPDIR/pkgstage" before after
	# Quem roda os testes pode ja ter o npass instalado em /usr/bin. O que
	# importa e que o DESTDIR nao o toque: compara inode, mtime e tamanho.
	before="$(stat -c '%i %Y %s' /usr/bin/npass 2>/dev/null || echo ausente)"
	run env DESTDIR="$destdir" PREFIX="/usr" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/bin/npass" ]
	[ -f "$destdir/usr/share/man/man1/npass.1" ]
	after="$(stat -c '%i %Y %s' /usr/bin/npass 2>/dev/null || echo ausente)"
	[ "$before" = "$after" ]
}

@test "binario instalado e reconstruido a partir do lib atual, nao um bin/npass velho esquecido" {
	# Marca o bin/npass do repo com um lixo que nao existe no source, para
	# provar que install.sh de fato reconstroi em vez de so copiar.
	echo "# MARCA_DE_ARQUIVO_VELHO_QUE_NAO_DEVE_SOBREVIVER" >> "$PROJECT_DIR/bin/npass"
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	run grep -c "MARCA_DE_ARQUIVO_VELHO_QUE_NAO_DEVE_SOBREVIVER" "$PREFIX/bin/npass"
	[ "$status" -ne 0 ]
}

@test "aviso quando PREFIX/bin nao esta no PATH" {
	run env PREFIX="$PREFIX" PATH="/usr/bin:/bin" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"não está no seu"*"PATH"* ]]
}

@test "sem aviso de PATH quando PREFIX/bin ja esta no PATH" {
	run env PREFIX="$PREFIX" PATH="$PREFIX/bin:/usr/bin:/bin" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[[ "$output" != *"não está no seu"*"PATH"* ]]
}

@test "PREFIX padrao e /usr (mesmo destino do PKGBUILD)" {
	local destdir="$BATS_TEST_TMPDIR/stage"
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/bin/npass" ]
	[ -f "$destdir/usr/share/man/man1/npass.1" ]
}

@test "--bindir=/usr/sbin coloca o binario em sbin e --uninstall o remove" {
	local destdir="$BATS_TEST_TMPDIR/stage"
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh" --bindir=/usr/sbin
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/sbin/npass" ]
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh" --bindir=/usr/sbin --uninstall
	[ ! -e "$destdir/usr/sbin/npass" ]
}

# --- handler do esquema npass:// (links do show renderizado -> npass open) -------------------------

@test "instala o .desktop do handler npass:// com o caminho ABSOLUTO do binario no Exec" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	local f="$PREFIX/share/applications/npass-open.desktop"
	[ -f "$f" ]
	grep -qx "Exec=$PREFIX/bin/npass open %u" "$f"
	grep -qx 'MimeType=x-scheme-handler/npass;' "$f"
	grep -qx 'NoDisplay=true' "$f"
	grep -qx 'Terminal=false' "$f"
	[[ "$output" == *"instalado: $f"* ]]
	run stat -c '%a' "$f"
	[ "$output" = "644" ]
}

@test "o Exec do .desktop acompanha --bindir e nao deixa o marcador @NPASS@" {
	env PREFIX="$PREFIX" BINDIR="$PREFIX/sbin" "$PROJECT_DIR/install.sh" >/dev/null
	local f="$PREFIX/share/applications/npass-open.desktop"
	grep -qx "Exec=$PREFIX/sbin/npass open %u" "$f"
	! grep -q '@NPASS@' "$f"
}

@test "com DESTDIR (empacotamento) o Exec NAO leva o DESTDIR, e o arquivo cai dentro dele" {
	local stage="$BATS_TEST_TMPDIR/stage"
	run env PREFIX=/usr DESTDIR="$stage" "$PROJECT_DIR/install.sh" --no-extensions
	[ "$status" -eq 0 ]
	local f="$stage/usr/share/applications/npass-open.desktop"
	[ -f "$f" ]
	grep -qx 'Exec=/usr/bin/npass open %u' "$f"
}

@test "--uninstall remove o .desktop tambem" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" >/dev/null
	[ -f "$PREFIX/share/applications/npass-open.desktop" ]
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/share/applications/npass-open.desktop" ]
}

@test "o modelo packaging/npass-open.desktop.in tem as chaves exigidas pelo spec e um unico %u" {
	local f="$PROJECT_DIR/packaging/npass-open.desktop.in"
	[ "$(sed -n 1p "$f")" = "[Desktop Entry]" ]
	grep -qx 'Type=Application' "$f"
	grep -q '^Name=' "$f"
	[ "$(grep -o '%u' "$f" | wc -l)" -eq 1 ]
	[ "$(grep -o '@NPASS@' "$f" | wc -l)" -eq 1 ]
}

@test "opção --tui baixa npass-tui do repositório correto e instala executável" {
	local mockbin="$BATS_TEST_TMPDIR/mockbin"
	local fixture="$BATS_TEST_TMPDIR/npass-tui.fixture"
	local log="$BATS_TEST_TMPDIR/curl.log"
	mkdir -p "$mockbin"
	printf '#!/usr/bin/env bash\necho "$@" >"$CURL_LOG"\ncat "$TUI_FIXTURE"\n' > "$mockbin/curl"
	chmod +x "$mockbin/curl"
	printf '#!/usr/bin/env bash\necho tui-test\n' > "$fixture"
	run env PREFIX="$PREFIX" PATH="$mockbin:$PATH" CURL_LOG="$log" TUI_FIXTURE="$fixture" "$PROJECT_DIR/install.sh" --tui
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass-tui" ]
	run "$PREFIX/bin/npass-tui"
	[ "$status" -eq 0 ]
	[ "$output" = "tui-test" ]
	grep -q 'https://raw.githubusercontent.com/HGBits/npass-tui/master/npass-tui' "$log"
}

@test "download com sintaxe inválida não instala npass-tui" {
	local mockbin="$BATS_TEST_TMPDIR/mockbin"
	local fixture="$BATS_TEST_TMPDIR/npass-tui.invalid"
	mkdir -p "$mockbin"
	printf '#!/usr/bin/env bash\ncat "$TUI_FIXTURE"\n' > "$mockbin/curl"
	chmod +x "$mockbin/curl"
	printf 'if then\n' > "$fixture"
	run env PREFIX="$PREFIX" PATH="$mockbin:$PATH" TUI_FIXTURE="$fixture" "$PROJECT_DIR/install.sh" --tui
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"sintaxe inválida"* ]]
}

@test "--no-tui não baixa nem instala a interface" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --no-tui
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
}

@test "--uninstall remove npass-tui quando instalado" {
	local mockbin="$BATS_TEST_TMPDIR/mockbin"
	local fixture="$BATS_TEST_TMPDIR/npass-tui.fixture"
	mkdir -p "$mockbin"
	printf '#!/usr/bin/env bash\ncat "$TUI_FIXTURE"\n' > "$mockbin/curl"
	chmod +x "$mockbin/curl"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
	env PREFIX="$PREFIX" PATH="$mockbin:$PATH" TUI_FIXTURE="$fixture" "$PROJECT_DIR/install.sh" --tui >/dev/null
	[ -x "$PREFIX/bin/npass-tui" ]
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
}
