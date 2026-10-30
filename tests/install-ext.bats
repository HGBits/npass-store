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
