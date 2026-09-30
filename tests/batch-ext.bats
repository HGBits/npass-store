#!/usr/bin/env bats
# Core que sustenta as extensoes: insert --batch, extension install, NPASS_BIN,
# e a regressao do mapa vazio (linha magica vazando como entrada).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	"$NPASS" init HG "$FPR" >/dev/null
}

commits() { git -C "$NPASS_STORE" rev-list --count HEAD; }

# --- insert --batch -----------------------------------------------------------

@test "insert --batch grava varias entradas, inclusive com varias linhas" {
	printf 'a/um\0l1\nl2\nl3\0b/dois\0so\0' | "$NPASS" insert --batch HG
	run "$NPASS" show HG a/um
	[ "$output" = $'l1\nl2\nl3' ]
	run "$NPASS" show HG b/dois
	[ "$output" = "so" ]
}

@test "insert --batch pula existentes sem -f e sobrescreve com -f" {
	printf 'velha\nvelha\n' | "$NPASS" insert HG a/um >/dev/null
	printf 'a/um\0nova\0' | "$NPASS" insert --batch HG
	run "$NPASS" show HG a/um
	[ "$output" = "velha" ]
	printf 'a/um\0nova\0' | "$NPASS" insert --batch -f HG
	run "$NPASS" show HG a/um
	[ "$output" = "nova" ]
}

@test "insert --batch faz UM commit para o lote inteiro" {
	local antes; antes="$(commits)"
	printf 'a\0x\0b\0y\0c\0z\0' | "$NPASS" insert --batch HG
	[ "$(commits)" -eq $((antes + 1)) ]
	run git -C "$NPASS_STORE" log -1 --format=%s
	[ "$output" = "insert-batch: HG" ]
}

@test "insert --batch recusa caminho logico com .. e nao grava nada" {
	run bash -c "printf '../fuga\0x\0' | '$NPASS' insert --batch HG"
	[ "$status" -ne 0 ]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "insert --batch sem ID mostra uso" {
	run "$NPASS" insert --batch
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
}

# --- regressao: mapa vazio nao vaza a linha magica como entrada -----------------

@test "ls de identidade vazia e depois de um insert nao lista a linha magica do mapa" {
	run "$NPASS" ls HG
	[[ "$output" != *"NPASS-MAP"* ]]
	printf 'x\nx\n' | "$NPASS" insert HG um/dois >/dev/null
	run "$NPASS" ls HG
	[[ "$output" != *"NPASS-MAP"* ]]
	[[ "$output" == *"um/dois"* ]]
}

@test "mapa ja contaminado pelo bug antigo e curado na leitura e na proxima escrita" {
	printf 'NPASS-MAP-1\nNPASS-MAP-1\t\n' \
		| gpg --batch --yes --trust-model always -r "$FPR" -e -o "$NPASS_STORE/HG/.map.gpg"
	run "$NPASS" ls HG
	[[ "$output" != *"NPASS-MAP"* ]]
	printf 'x\nx\n' | "$NPASS" insert HG novo >/dev/null
	run gpg --batch -q -d "$NPASS_STORE/HG/.map.gpg"
	[ "$(printf '%s\n' "$output" | grep -c '^NPASS-MAP-1')" -eq 1 ]
}

# --- extension install ---------------------------------------------------------

mkext() {
	printf '#!/bin/bash\necho "ola $*"\n' >"$BATS_TEST_TMPDIR/npass-ola"
	chmod 755 "$BATS_TEST_TMPDIR/npass-ola"
}

@test "extension install copia, assina e a extensao passa a executar" {
	mkext
	run "$NPASS" extension install "$BATS_TEST_TMPDIR/npass-ola" "$FPR"
	[ "$status" -eq 0 ]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-ola" ]
	[ -f "$NPASS_EXTENSIONS_DIR/npass-ola.sig" ]
	NPASS_ENABLE_EXTENSIONS=1 run "$NPASS" ola mundo
	[ "$status" -eq 0 ]
	[ "$output" = "ola mundo" ]
}

@test "extension install recusa nome fora do padrao npass-NOME" {
	printf '#!/bin/bash\n' >"$BATS_TEST_TMPDIR/qualquer"
	run "$NPASS" extension install "$BATS_TEST_TMPDIR/qualquer" "$FPR"
	[ "$status" -ne 0 ]
	[ ! -e "$NPASS_EXTENSIONS_DIR/qualquer" ]
}

@test "extension install recusa symlink como origem" {
	mkext
	ln -s "$BATS_TEST_TMPDIR/npass-ola" "$BATS_TEST_TMPDIR/npass-link"
	run "$NPASS" extension install "$BATS_TEST_TMPDIR/npass-link" "$FPR"
	[ "$status" -ne 0 ]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-link" ]
}

@test "extension install substitui uma versao anterior sem escrever atraves de symlink" {
	mkext
	mkdir -p "$NPASS_EXTENSIONS_DIR"
	echo alvo >"$BATS_TEST_TMPDIR/alvo"
	ln -s "$BATS_TEST_TMPDIR/alvo" "$NPASS_EXTENSIONS_DIR/npass-ola"
	"$NPASS" extension install "$BATS_TEST_TMPDIR/npass-ola" "$FPR"
	[ ! -L "$NPASS_EXTENSIONS_DIR/npass-ola" ]
	[ "$(cat "$BATS_TEST_TMPDIR/alvo")" = "alvo" ]
}

# --- NPASS_BIN -----------------------------------------------------------------

@test "a extensao recebe NPASS_BIN apontando para o npass que a executou" {
	printf '#!/bin/bash\nprintf "%%s" "$NPASS_BIN"\n' >"$BATS_TEST_TMPDIR/npass-quem"
	chmod 755 "$BATS_TEST_TMPDIR/npass-quem"
	"$NPASS" extension install "$BATS_TEST_TMPDIR/npass-quem" "$FPR" >/dev/null
	NPASS_ENABLE_EXTENSIONS=1 run "$NPASS" quem
	[ "$status" -eq 0 ]
	[ "$output" = "$(readlink -f "$NPASS")" ]
}
