#!/usr/bin/env bats
# O instalador so instala artefatos assinados pela chave oficial do NPASS.

setup() {
	[[ "$EUID" -eq 0 ]] || skip "testa instalação global root-owned"
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export PREFIX="$BATS_TEST_TMPDIR/prefix"
	export SOURCE="$BATS_TEST_TMPDIR/source"
	mkdir -p "$SOURCE"
	printf '#!/usr/bin/env bash\necho nao deveria rodar\n' >"$SOURCE/npass-test"
	chmod 755 "$SOURCE/npass-test"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true GIT_TERMINAL_PROMPT=0
}

inst() { "$PROJECT_DIR/install.sh" --prefix="$PREFIX" --no-tui "$@"; }

@test "instalacao principal instala a chave publica no share global" {
	run inst --no-extensions
	[ "$status" -eq 0 ]
	[ -f "$PREFIX/share/npass/extension-signing-key.asc" ]
	cmp "$PROJECT_DIR/packaging/npass-release.asc" "$PREFIX/share/npass/extension-signing-key.asc"
	[ "$(stat -c %a "$PREFIX/share/npass/extension-signing-key.asc")" = "644" ]
}

@test "extensao sem assinatura e recusada sem ser instalada" {
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"assinatura ausente/não regular"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-test" ]
}

@test "extensao assinada por chave externa e recusada" {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$SOURCE/npass-test.sig" "$SOURCE/npass-test"
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"assinatura inválida"* ]]
	[ ! -e "$PREFIX/share/npass/extensions/npass-test" ]
}

@test "extensions-only instala a chave de confianca e nao assina codigo com chave do usuario" {
	inst --no-extensions >/dev/null
	run bash -c "printf 's\n' | '$PROJECT_DIR/install.sh' --prefix='$PREFIX' --no-tui --extensions-only --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[ -f "$PREFIX/share/npass/extension-signing-key.asc" ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-test.sig" ]
	[[ "$output" == *"assinatura ausente/não regular"* ]]
}

@test "DESTDIR rejeita instalação interativa de extensoes" {
	run env DESTDIR="$BATS_TEST_TMPDIR/stage" "$PROJECT_DIR/install.sh" --prefix=/usr --extensions
	[ "$status" -ne 0 ]
	[[ "$output" == *"DESTDIR"* ]]
}

@test "uninstall remove chave e extensoes compartilhadas" {
	run inst --no-extensions
	mkdir -p "$PREFIX/share/npass/extensions" "$PREFIX/share/npass/helpers"
	printf 'x\n' >"$PREFIX/share/npass/extensions/npass-stale"
	printf 'x\n' >"$PREFIX/share/npass/helpers/npass-passkeyd"
	run env PREFIX="$PREFIX" "$PROJECT_DIR/install.sh" --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/share/npass/extension-signing-key.asc" ]
	[ ! -e "$PREFIX/share/npass/extensions" ]
	[ ! -e "$PREFIX/share/npass/helpers" ]
}

@test "instalador remove um único prefixo e o core lista os nomes lógicos" {
	local fixture="$BATS_TEST_TMPDIR/project"
	mkdir -p "$fixture/packaging" "$fixture/lib" "$PREFIX/share" "$PREFIX/share"
	cp "$PROJECT_DIR/install.sh" "$fixture/install.sh"
	cp "$PROJECT_DIR/lib/extension-names.bash" "$fixture/lib/extension-names.bash"
	gpg --batch --export "$FPR" >"$fixture/packaging/npass-release.asc"
	for artifact in npass-audit npass-clip-x11.bash; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$SOURCE/$artifact"
		chmod 755 "$SOURCE/$artifact"
		gpg --batch --yes --default-key "$FPR" --detach-sign -o "$SOURCE/$artifact.sig" "$SOURCE/$artifact"
	done
	run bash -c "printf 's\\n' | '$fixture/install.sh' --prefix='$PREFIX' --no-tui --extensions-only --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[ -x "$PREFIX/share/npass/extensions/npass-audit" ]
	[ -x "$PREFIX/share/npass/extensions/npass-clip-x11" ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-npass-audit" ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-npass-clip-x11" ]
	run env XDG_DATA_DIRS="$PREFIX/share" "$PROJECT_DIR/bin/npass" extension list
	[ "$status" -eq 0 ]
	[[ "$output" == *"audit: ok"* ]]
	[[ "$output" == *"clip-x11: ok"* ]]
}

@test "instalador recusa prefixo duplicado e formato de nome inválido" {
	local fixture="$BATS_TEST_TMPDIR/project"
	mkdir -p "$fixture/packaging" "$fixture/lib" "$PREFIX/share"
	cp "$PROJECT_DIR/install.sh" "$fixture/install.sh"
	cp "$PROJECT_DIR/lib/extension-names.bash" "$fixture/lib/extension-names.bash"
	gpg --batch --export "$FPR" >"$fixture/packaging/npass-release.asc"
	for artifact in npass-npass-audit npass-Audit npass-audit.bash.bash; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$SOURCE/$artifact"
		chmod 755 "$SOURCE/$artifact"
		gpg --batch --yes --default-key "$FPR" --detach-sign -o "$SOURCE/$artifact.sig" "$SOURCE/$artifact"
	done
	run bash -c "printf 's\\n' | '$fixture/install.sh' --prefix='$PREFIX' --no-tui --extensions-only --extensions-src='$SOURCE'"
	[ "$status" -eq 0 ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-npass-audit" ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-Audit" ]
	[ ! -e "$PREFIX/share/npass/extensions/npass-audit.bash" ]
	[[ "$output" == *"nome de extensão inválido"* ]]
}
