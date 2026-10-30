#!/usr/bin/env bats

setup() {
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export PREFIX="$BATS_TEST_TMPDIR/prefix"
	export DESTDIR=""
	unset NPASS_STORE NPASS_GPG NPASS_LANG 2>/dev/null || true
}

@test "instala binario e man page em PREFIX/bin e PREFIX/share/man/man1" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
	[ -f "$PREFIX/share/man/man1/npass.1" ]
	[ -f "$PREFIX/share/npass/extension-signing-key.asc" ]
}

@test "binario instalado executa e responde ao help" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	run "$PREFIX/bin/npass" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"npass"* ]]
}

@test "permissoes: binario 755, man page 644" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	run stat -c '%a' "$PREFIX/bin/npass"
	[ "$output" = "755" ]
	run stat -c '%a' "$PREFIX/share/man/man1/npass.1"
	[ "$output" = "644" ]
	run stat -c '%a' "$PREFIX/share/npass/extension-signing-key.asc"
	[ "$output" = "644" ]
}

@test "instalar duas vezes seguidas nao falha (idempotente)" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
}

@test "--uninstall remove exatamente o que foi instalado" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass" ]
	[ ! -e "$PREFIX/share/man/man1/npass.1" ]
	[ ! -e "$PREFIX/share/npass/extension-signing-key.asc" ]
}

@test "--uninstall sem nada instalado nao falha, so avisa" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local --uninstall
	[ "$status" -eq 0 ]
	[[ "$output" == *"nada instalado"* ]]
}

@test "--prefix=PATH funciona igual a variavel de ambiente PREFIX" {
	run "$PROJECT_DIR/install.sh" --build-local "--prefix=$PREFIX"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
}

@test "DESTDIR + PREFIX (empacotamento) instala dentro do staging, nao no sistema real" {
	local destdir="$BATS_TEST_TMPDIR/pkgstage" before after
	# Quem roda os testes pode ja ter o npass instalado em /usr/bin. O que
	# importa e que o DESTDIR nao o toque: compara inode, mtime e tamanho.
	before="$(stat -c '%i %Y %s' /usr/bin/npass 2>/dev/null || echo ausente)"
	run env DESTDIR="$destdir" PREFIX="/usr" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/bin/npass" ]
	[ -f "$destdir/usr/share/man/man1/npass.1" ]
	[ -f "$destdir/usr/share/npass/extension-signing-key.asc" ]
	after="$(stat -c '%i %Y %s' /usr/bin/npass 2>/dev/null || echo ausente)"
	[ "$before" = "$after" ]
}

@test "binario instalado e reconstruido a partir do lib atual, nao um bin/npass velho esquecido" {
	# Marca o bin/npass do repo com um lixo que nao existe no source, para
	# provar que install.sh de fato reconstroi em vez de so copiar.
	echo "# MARCA_DE_ARQUIVO_VELHO_QUE_NAO_DEVE_SOBREVIVER" >> "$PROJECT_DIR/bin/npass"
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	run grep -c "MARCA_DE_ARQUIVO_VELHO_QUE_NAO_DEVE_SOBREVIVER" "$PREFIX/bin/npass"
	[ "$status" -ne 0 ]
}

@test "aviso quando PREFIX/bin nao esta no PATH" {
	run env PREFIX="$PREFIX" PATH="/usr/bin:/bin" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[[ "$output" == *"não está no seu"*"PATH"* ]]
}

@test "sem aviso de PATH quando PREFIX/bin ja esta no PATH" {
	run env PREFIX="$PREFIX" PATH="$PREFIX/bin:/usr/bin:/bin" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[[ "$output" != *"não está no seu"*"PATH"* ]]
}

@test "PREFIX padrao e /usr (mesmo destino do PKGBUILD)" {
	local destdir="$BATS_TEST_TMPDIR/stage"
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh" --build-local
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/bin/npass" ]
	[ -f "$destdir/usr/share/man/man1/npass.1" ]
}

@test "--bindir=/usr/sbin coloca o binario em sbin e --uninstall o remove" {
	local destdir="$BATS_TEST_TMPDIR/stage"
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh" --build-local --bindir=/usr/sbin
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/sbin/npass" ]
	run env -u PREFIX DESTDIR="$destdir" "$PROJECT_DIR/install.sh" --build-local --bindir=/usr/sbin --uninstall
	[ ! -e "$destdir/usr/sbin/npass" ]
}

# --- handler do esquema npass:// (links do show renderizado -> npass open) -------------------------

@test "instala o .desktop do handler npass:// com o caminho ABSOLUTO do binario no Exec" {
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local
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
	env PREFIX="$PREFIX" BINDIR="$PREFIX/sbin" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	local f="$PREFIX/share/applications/npass-open.desktop"
	grep -qx "Exec=$PREFIX/sbin/npass open %u" "$f"
	! grep -q '@NPASS@' "$f"
}

@test "com DESTDIR (empacotamento) o Exec NAO leva o DESTDIR, e o arquivo cai dentro dele" {
	local stage="$BATS_TEST_TMPDIR/stage"
	run env PREFIX=/usr DESTDIR="$stage" "$PROJECT_DIR/install.sh" --build-local --no-extensions
	[ "$status" -eq 0 ]
	local f="$stage/usr/share/applications/npass-open.desktop"
	[ -f "$f" ]
	grep -qx 'Exec=/usr/bin/npass open %u' "$f"
}

@test "--uninstall remove o .desktop tambem" {
	env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local >/dev/null
	[ -f "$PREFIX/share/applications/npass-open.desktop" ]
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local --uninstall
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

# --------------------------------------------------------------------------
# Core npass: release assinado, baixado e VERIFICADO antes de instalar
# --------------------------------------------------------------------------

core_release() {
	export CORE_RELEASE_DIR="$BATS_TEST_TMPDIR/core-release"
	export CORE_KEY="$BATS_TEST_TMPDIR/core-release-key.asc"
	export MOCKBIN="$BATS_TEST_TMPDIR/core-mockbin" CURL_LOG="$BATS_TEST_TMPDIR/core-curl.log"
	local gh stage
	gh="$(mktemp -d /tmp/npass-core-gpg.XXXXXX)"
	chmod 700 "$gh"
	mkdir -p "$CORE_RELEASE_DIR" "$MOCKBIN"
	: >"$CURL_LOG"
	GNUPGHOME="$gh" gpg --batch --quiet --passphrase '' --quick-generate-key 'Core Release Teste <core-release@example.invalid>' ed25519 sign never 2>/dev/null
	GNUPGHOME="$gh" gpg --batch --armor --export >"$CORE_KEY"
	CORE_FPR="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys | awk -F: '/^fpr:/ {print $10; exit}')"
	stage="$BATS_TEST_TMPDIR/core-stage"
	mkdir -p "$stage/bin" "$stage/share/man/man1" "$stage/share/npass/encrypts_alternatives" "$stage/share/applications"
	printf '#!/usr/bin/env bash\necho core-release-test\n' >"$stage/bin/npass"
	chmod 755 "$stage/bin/npass"
	printf '.TH NPASS 1\n' >"$stage/share/man/man1/npass.1"
	printf '[large]\n11111\tabacus\n' >"$stage/share/npass/encrypts_alternatives/wordlist.txt"
	printf '[Desktop Entry]\nExec=@NPASS@ open %%u\n' >"$stage/share/applications/npass-open.desktop.in"
	install -m 644 "$CORE_KEY" "$stage/share/npass/extension-signing-key.asc"
	tar -czf "$CORE_RELEASE_DIR/npass-core.tar.gz" -C "$stage" bin share
	GNUPGHOME="$gh" gpg --batch --yes --armor --detach-sign --output "$CORE_RELEASE_DIR/npass-core.tar.gz.asc" "$CORE_RELEASE_DIR/npass-core.tar.gz"
	cp "$CORE_KEY" "$CORE_RELEASE_DIR/npass-release.asc"
	CORE_GH="$gh"
	cat >"$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift ;;
		--) shift; url="$1"; break ;;
	esac
	shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
src="$CORE_RELEASE_DIR/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
MOCK
	chmod +x "$MOCKBIN/curl"
}

core_cleanup() {
	[[ -n ${CORE_GH:-} ]] || return 0
	GNUPGHOME="$CORE_GH" gpgconf --kill gpg-agent 2>/dev/null || true
	rm -rf -- "$CORE_GH"
}

@test "instala core baixado de release somente depois de validar assinatura" {
	core_release
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" CORE_RELEASE_DIR="$CORE_RELEASE_DIR" \
		NPASS_CORE_KEY="$CORE_KEY" NPASS_CORE_BASE_URL="https://example.invalid/npass/releases" \
		"$PROJECT_DIR/install.sh" --no-extensions
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
	[[ "$output" == *"release core verificada"* ]]
	[ "$("$PREFIX/bin/npass")" = "core-release-test" ]
	grep -qxF 'https://example.invalid/npass/releases/latest/download/npass-core.tar.gz' "$CURL_LOG"
	grep -qxF 'https://example.invalid/npass/releases/latest/download/npass-core.tar.gz.asc' "$CURL_LOG"
	[[ "$output" == *"$CORE_FPR"* ]]
}

@test "core-ref seleciona release especifica" {
	core_release
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" CORE_RELEASE_DIR="$CORE_RELEASE_DIR" \
		NPASS_CORE_KEY="$CORE_KEY" NPASS_CORE_BASE_URL="https://example.invalid/npass/releases" \
		"$PROJECT_DIR/install.sh" --core-ref=v9.8 --no-extensions
	[ "$status" -eq 0 ]
	grep -qxF 'https://example.invalid/npass/releases/download/v9.8/npass-core.tar.gz' "$CURL_LOG"
}

@test "core adulterado depois de assinado é recusado e nada é instalado" {
	core_release
	printf "adulterado" >>"$CORE_RELEASE_DIR/npass-core.tar.gz"
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" CORE_RELEASE_DIR="$CORE_RELEASE_DIR" \
		NPASS_CORE_KEY="$CORE_KEY" NPASS_CORE_BASE_URL="https://example.invalid/npass/releases" \
		"$PROJECT_DIR/install.sh" --no-extensions
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass" ]
	[[ "$output" == *"assinatura do pacote core INVÁLIDA"* ]]
}

@test "execução via stdin instala o pacote completo sem checkout" {
	core_release
	run bash -c 'env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" CORE_RELEASE_DIR="$CORE_RELEASE_DIR" NPASS_CORE_KEY="$CORE_KEY" NPASS_CORE_BASE_URL="https://example.invalid/npass/releases" bash -s -- --no-extensions --no-tui < "$PROJECT_DIR/install.sh"' _ 
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass" ]
	[ -s "$PREFIX/share/man/man1/npass.1" ]
	[ -s "$PREFIX/share/npass/encrypts_alternatives/wordlist.txt" ]
	[ -s "$PREFIX/share/applications/npass-open.desktop" ]
	[ -s "$PREFIX/share/npass/extension-signing-key.asc" ]
}

# --------------------------------------------------------------------------
# npass-tui: release assinado, baixado e VERIFICADO antes de instalar
# --------------------------------------------------------------------------

# Cria, em $TUI_DIR, um "release" de mentira: npass-tui + npass-tui.asc assinado
# por uma chave descartável cuja parte pública fica em $TUI_KEY. O curl é um mock
# que serve esses arquivos pelo nome e registra as URLs pedidas.
tui_release() {
	export TUI_DIR="$BATS_TEST_TMPDIR/release" TUI_KEY="$BATS_TEST_TMPDIR/release-key.asc"
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
	local gh
	gh="$(mktemp -d /tmp/npass-tui-gpg.XXXXXX)"
	chmod 700 "$gh"
	mkdir -p "$TUI_DIR" "$MOCKBIN"
	: >"$CURL_LOG"
	GNUPGHOME="$gh" gpg --batch --quiet --passphrase '' --quick-generate-key 'Release Teste <rel@example.invalid>' ed25519 sign never 2>/dev/null
	GNUPGHOME="$gh" gpg --batch --armor --export >"$TUI_KEY"
	TUI_FPR="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys | awk -F: '/^fpr:/ {print $10; exit}')"
	printf '#!/usr/bin/env bash\necho tui-test\n' >"$TUI_DIR/npass-tui"
	GNUPGHOME="$gh" gpg --batch --yes --armor --detach-sign --output "$TUI_DIR/npass-tui.asc" "$TUI_DIR/npass-tui"
	TUI_GH="$gh"
	cat >"$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift ;;
	--) shift; url="$1"; break ;;
	esac
	shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
src="$TUI_DIR/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
MOCK
	chmod +x "$MOCKBIN/curl"
	# o instalador nunca deve clonar nem compilar o npass-tui
	printf '#!/usr/bin/env bash\necho git >>"$CURL_LOG"\nexit 99\n' >"$MOCKBIN/git"
	chmod +x "$MOCKBIN/git"
}

tui_cleanup() {
	[[ -n ${TUI_GH:-} ]] || return 0
	GNUPGHOME="$TUI_GH" gpgconf --kill gpg-agent 2>/dev/null || true
	rm -rf -- "$TUI_GH"
}

teardown() { tui_cleanup; core_cleanup; }

run_tui_install() {
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" TUI_DIR="$TUI_DIR" \
		NPASS_TUI_KEY="$TUI_KEY" "$PROJECT_DIR/install.sh" --build-local --tui "$@"
}

@test "--tui baixa binário e .asc do release, verifica a assinatura e instala" {
	tui_release
	run_tui_install
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"assinatura verificada"* ]]
	[[ "$output" == *"$TUI_FPR"* ]]
	run "$PREFIX/bin/npass-tui"
	[ "$output" = "tui-test" ]
	grep -qxF 'https://github.com/HGBits/npass-tui/releases/latest/download/npass-tui' "$CURL_LOG"
	grep -qxF 'https://github.com/HGBits/npass-tui/releases/latest/download/npass-tui.asc' "$CURL_LOG"
}

@test "--tui-ref=TAG baixa o release daquela tag" {
	tui_release
	run_tui_install --tui-ref=v1.2
	[ "$status" -eq 0 ]
	grep -qxF 'https://github.com/HGBits/npass-tui/releases/download/v1.2/npass-tui' "$CURL_LOG"
}

@test "o instalador não clona nem compila o npass-tui" {
	tui_release
	run_tui_install
	[ "$status" -eq 0 ]
	! grep -qx git "$CURL_LOG"
}

@test "binário adulterado depois de assinado não é instalado e o install.sh sai com erro" {
	tui_release
	printf '#!/usr/bin/env bash\necho adulterado\n' >"$TUI_DIR/npass-tui"
	run_tui_install
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"INVÁLIDA"* ]]
	# a CLI em si continua instalada
	[ -x "$PREFIX/bin/npass" ]
}

@test "assinatura de OUTRA chave (mesmo válida) é recusada" {
	tui_release
	local gh2
	gh2="$(mktemp -d /tmp/npass-tui-gpg2.XXXXXX)"
	chmod 700 "$gh2"
	GNUPGHOME="$gh2" gpg --batch --quiet --passphrase '' --quick-generate-key 'Atacante <x@example.invalid>' ed25519 sign never 2>/dev/null
	rm -f "$TUI_DIR/npass-tui.asc"
	GNUPGHOME="$gh2" gpg --batch --armor --detach-sign --output "$TUI_DIR/npass-tui.asc" "$TUI_DIR/npass-tui"
	GNUPGHOME="$gh2" gpgconf --kill gpg-agent 2>/dev/null || true
	rm -rf -- "$gh2"
	run_tui_install
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
}

@test "release sem .asc não instala o npass-tui" {
	tui_release
	rm -f "$TUI_DIR/npass-tui.asc"
	run_tui_install
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"falha ao baixar"* ]]
}

@test "sem chave pública de release recusa antes de baixar qualquer coisa" {
	tui_release
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" TUI_DIR="$TUI_DIR" \
		NPASS_TUI_KEY="$BATS_TEST_TMPDIR/nao-existe.asc" "$PROJECT_DIR/install.sh" --build-local --tui
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"chave pública de release não encontrada"* ]]
	[ ! -s "$CURL_LOG" ]
}

@test "arquivo de chave com mais de uma chave pública é recusado" {
	tui_release
	local gh2
	gh2="$(mktemp -d /tmp/npass-tui-gpg2.XXXXXX)"
	chmod 700 "$gh2"
	GNUPGHOME="$gh2" gpg --batch --quiet --passphrase '' --quick-generate-key 'Outra <o@example.invalid>' ed25519 sign never 2>/dev/null
	GNUPGHOME="$gh2" gpg --batch --armor --export >>"$TUI_KEY"
	GNUPGHOME="$gh2" gpgconf --kill gpg-agent 2>/dev/null || true
	rm -rf -- "$gh2"
	run_tui_install
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"UMA chave pública"* ]]
}

@test "binário assinado mas com sintaxe inválida não é instalado" {
	tui_release
	printf 'if then\n' >"$TUI_DIR/npass-tui"
	rm -f "$TUI_DIR/npass-tui.asc"
	GNUPGHOME="$TUI_GH" gpg --batch --armor --detach-sign --output "$TUI_DIR/npass-tui.asc" "$TUI_DIR/npass-tui"
	run_tui_install
	[ "$status" -ne 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[[ "$output" == *"sintaxe inválida"* ]]
}

@test "o instalador não usa nem altera o chaveiro do usuário" {
	tui_release
	local home_gpg="$BATS_TEST_TMPDIR/gnupg-usuario"
	mkdir -m 700 "$home_gpg"
	run env GNUPGHOME="$home_gpg" PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" TUI_DIR="$TUI_DIR" \
		NPASS_TUI_KEY="$TUI_KEY" "$PROJECT_DIR/install.sh" --build-local --tui
	[ "$status" -eq 0 ]
	[ -z "$(ls -A "$home_gpg" | grep -v '^S\.\|^\.#\|^random_seed$' || true)" ]
}

@test "--no-tui não baixa nem instala a interface" {
	tui_release
	run env PREFIX="$PREFIX" PATH="$MOCKBIN:$PATH" CURL_LOG="$CURL_LOG" "$PROJECT_DIR/install.sh" --build-local --no-tui
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
	[ ! -s "$CURL_LOG" ]
}

@test "--uninstall remove npass-tui quando instalado" {
	tui_release
	run_tui_install
	[ -x "$PREFIX/bin/npass-tui" ]
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --build-local --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/bin/npass-tui" ]
}
