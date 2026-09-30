#!/usr/bin/env bats
# Cobre o patch m2: git automatico, clip por campo, store em ~/.npass,
# nomes de blob legiveis e comando identities.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	# sem identidade git global: o npass precisa se virar sozinho
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	# clipboard falso: wl-copy grava stdin num arquivo
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CLIPFILE="$BATS_TEST_TMPDIR/clip.out"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\n[[ "$1" == "--clear" ]] && exit 0\ncat > "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-copy"
	printf '#!/bin/bash\ncat "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-paste"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" WAYLAND_DISPLAY=wayland-test NPASS_CLIP_TIME=5
}

teardown() { pkill -f "sleep 5$" 2>/dev/null || true; }

mkentry() {
	"$NPASS" init HG "$FPR" >/dev/null
	printf 'pw\npw\n' | "$NPASS" insert HG Mips/Natty >/dev/null
	printf 'S3nh4!\nemail: nat@x.com\nuser: natty\n# nome-real: Natty Corp\n# email-alias: a@x.com\n' >"$BATS_TEST_TMPDIR/body"
	printf '#!/bin/bash\ncp "%s" "$1"\n' "$BATS_TEST_TMPDIR/body" >"$BATS_TEST_TMPDIR/ed.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed.sh"
	EDITOR="$BATS_TEST_TMPDIR/ed.sh" "$NPASS" edit HG Mips/Natty >/dev/null
}

# --- 1. git automatico -------------------------------------------------------

@test "init cria o repo git do store e o commit inicial, sem config git do usuario" {
	run "$NPASS" init HG "$FPR"
	[ "$status" -eq 0 ]
	[ -d "$NPASS_STORE/.git" ]
	run git -C "$NPASS_STORE" log --format=%s
	[[ "$output" == *"init: HG"* ]]
	[[ "$output" == *"init: store"* ]]
}

@test "operacoes commitam sozinhas e .map.lock fica fora do repo" {
	mkentry
	run git -C "$NPASS_STORE" log --format=%s
	[[ "$output" == *"insert: HG"* ]]
	[[ "$output" == *"edit: HG"* ]]
	run git -C "$NPASS_STORE" ls-files
	[[ "$output" != *".map.lock"* ]]
	[ -z "$(git -C "$NPASS_STORE" status --short)" ]
}

@test "store legado sem repo ganha um no primeiro comando que altera algo" {
	mkentry
	rm -rf "$NPASS_STORE/.git"
	printf 'x\nx\n' | "$NPASS" insert HG Mail/Two
	[ -d "$NPASS_STORE/.git" ]
}

# --- 2. clip por campo -------------------------------------------------------

@test "clip ID CAMINHO copia so a senha (primeira linha)" {
	mkentry
	run "$NPASS" clip HG Mips/Natty
	[ "$status" -eq 0 ]
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "S3nh4!" ]
}

@test "clip pass ID CAMINHO equivale ao padrao" {
	mkentry
	"$NPASS" clip pass HG Mips/Natty
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "S3nh4!" ]
}

@test "clip CAMPO ID CAMINHO copia o valor do campo (case-insensitive)" {
	mkentry
	"$NPASS" clip USER HG Mips/Natty
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "natty" ]
}

@test "clip com campo: chave exata vence prefixo; prefixo unico funciona" {
	mkentry
	"$NPASS" clip email HG Mips/Natty
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "nat@x.com" ]
	"$NPASS" clip email-a HG Mips/Natty
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "a@x.com" ]
}

@test "clip acha campos gravados como '# chave: valor' (formato do migrate-secrets)" {
	mkentry
	"$NPASS" clip nome-real HG Mips/Natty
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "Natty Corp" ]
}

@test "clip all copia a entrada inteira" {
	mkentry
	"$NPASS" clip all HG Mips/Natty
	sleep 0.3
	[ "$(wc -l <"$CLIPFILE")" -ge 3 ]
}

@test "clip com campo inexistente falha e lista so as chaves, nunca valores" {
	mkentry
	run "$NPASS" clip telefone HG Mips/Natty
	[ "$status" -ne 0 ]
	[[ "$output" == *"email"* ]]
	[[ "$output" != *"nat@x.com"* ]]
}

@test "clip com numero de argumentos invalido mostra uso" {
	run "$NPASS" clip HG
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
}

# --- 3. store padrao ---------------------------------------------------------

@test "sem NPASS_STORE o store padrao e \$HOME/.npass" {
	unset NPASS_STORE
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
	run "$NPASS" init HG "$FPR"
	[ "$status" -eq 0 ]
	[ -f "$HOME/.npass/HG/.gpg-id" ]
	[ ! -e "$HOME/.local/share/npass/HG" ]
}

@test "aviso (sem mover nada) quando existe store no local antigo" {
	unset NPASS_STORE
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.local/share/npass/HG"
	touch "$HOME/.local/share/npass/HG/.gpg-id"
	run "$NPASS" identities
	[[ "$output" == *"store antigo"* ]]
	[ -f "$HOME/.local/share/npass/HG/.gpg-id" ]
}

# --- 4. nomes legiveis -------------------------------------------------------

@test "blobs novos tem nome legivel e nao derivam do caminho logico" {
	mkentry
	run ls "$NPASS_STORE/HG/blobs"
	[[ "$output" =~ ^[A-Z][a-z]{5,8}\.gpg$ ]]
}

@test "nomes de blob nao colidem nem ignorando maiusculas (300 nomes)" {
	"$NPASS" init HG "$FPR" >/dev/null
	source <(sed -n '/^NPASS_SYL_C/,/^# --- identities/p' "$BATS_TEST_DIRNAME/../lib/02-identity.bash" | head -n -1)
	local i n
	for i in $(seq 1 300); do
		n="$(npass_new_blob_name "$NPASS_STORE/HG")"
		touch "$NPASS_STORE/HG/blobs/$n.gpg"
	done
	[ "$(ls "$NPASS_STORE/HG/blobs" | wc -l)" -eq 300 ]
	[ "$(ls "$NPASS_STORE/HG/blobs" | tr A-Z a-z | sort -u | wc -l)" -eq 300 ]
}

# --- 5. identities -----------------------------------------------------------

@test "identities lista 'NOME - N senhas' sem decifrar nada" {
	"$NPASS" init HG "$FPR" >/dev/null
	"$NPASS" init Vupon "$FPR2" >/dev/null
	printf 'a\na\n' | "$NPASS" insert HG a/1 >/dev/null
	printf 'a\na\n' | "$NPASS" insert HG a/2 >/dev/null
	printf 'a\na\n' | "$NPASS" insert Vupon b/1 >/dev/null
	run "$NPASS" identities
	[ "$status" -eq 0 ]
	[[ "$output" == *"HG - 2 senhas"* ]]
	[[ "$output" == *"Vupon - 1 senha"* ]]
	[[ "$output" != *"1 senhas"* ]]
}

@test "identities num store vazio nao falha" {
	run "$NPASS" identities
	[ "$status" -eq 0 ]
}
