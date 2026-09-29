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
	local destdir="$BATS_TEST_TMPDIR/pkgstage"
	run env DESTDIR="$destdir" PREFIX="/usr" "$PROJECT_DIR/install.sh"
	[ "$status" -eq 0 ]
	[ -x "$destdir/usr/bin/npass" ]
	[ -f "$destdir/usr/share/man/man1/npass.1" ]
	[ ! -e "/usr/bin/npass" ]
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
