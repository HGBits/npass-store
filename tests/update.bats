#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
	"$NPASS" init personal "$FPR"
}

# --- generate ---------------------------------------------------------

@test "generate cria senha do comprimento pedido" {
	run "$NPASS" generate personal email/new 16
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 16 ]
}

@test "generate --no-symbols so usa alfanumerico" {
	run "$NPASS" generate -n personal email/new 40
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[A-Za-z0-9]{40}$ ]]
}

@test "generate --in-place preserva linhas seguintes (ex.: OTP)" {
	printf 'senhavelha\nsenhavelha\n' | "$NPASS" insert personal work/aws
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal work/aws
	"$NPASS" generate -f --in-place personal work/aws 12 >/dev/null
	run "$NPASS" show personal work/aws
	[[ "$output" == *"otpauth://"* ]]
	[[ "$output" != *"senhavelha"* ]]
}

# --- edit ---------------------------------------------------------------

@test "edit grava o conteudo produzido pelo \$EDITOR" {
	printf 'echo novo-conteudo > "$1"' > "$BATS_TEST_TMPDIR/fake_editor.sh"
	chmod +x "$BATS_TEST_TMPDIR/fake_editor.sh"
	EDITOR="$BATS_TEST_TMPDIR/fake_editor.sh" run "$NPASS" edit personal notes/x
	[ "$status" -eq 0 ]
	run "$NPASS" show personal notes/x
	[ "$output" = "novo-conteudo" ]
}

@test "edit sem mudanca real nao falha e nao regrava" {
	printf 'a\na\n' | "$NPASS" insert personal notes/y
	printf '#!/bin/sh\ncat "$1" > /tmp/npass_edit_noop_check\n' > "$BATS_TEST_TMPDIR/noop_editor.sh"
	chmod +x "$BATS_TEST_TMPDIR/noop_editor.sh"
	EDITOR="$BATS_TEST_TMPDIR/noop_editor.sh" run "$NPASS" edit personal notes/y
	[ "$status" -eq 0 ]
	run "$NPASS" show personal notes/y
	[ "$output" = "a" ]
}

# --- update: geracao automatica ------------------------------------------

@test "update gera nova senha e preserva a URI OTP" {
	printf 'senhavelha\nsenhavelha\n' | "$NPASS" insert personal work/aws
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal work/aws
	printf 'y\n' | "$NPASS" update -f -l 14 personal work/aws
	run "$NPASS" show personal work/aws
	local newpw; newpw="$(head -n1 <<<"$output")"
	[ "${#newpw}" -eq 14 ]
	[[ "$output" == *"otpauth://"* ]]
	[[ "$output" != *"senhavelha"* ]]
}

@test "update --auto-length usa o comprimento da senha antiga" {
	printf 'abcdefgh\nabcdefgh\n' | "$NPASS" insert personal email/x
	printf 'y\n' | "$NPASS" update -f -a personal email/x
	run "$NPASS" show personal email/x
	[ "${#output}" -eq 8 ]
}

@test "update -f sem resposta interativa ainda gera (forcado)" {
	printf 'abc\nabc\n' | "$NPASS" insert personal email/z
	run "$NPASS" update -f -l 10 personal email/z
	[ "$status" -eq 0 ]
	run "$NPASS" show personal email/z
	[ "${#output}" -eq 10 ]
	[ "$output" != "abc" ]
}

@test "update sem -f e resposta N mantem a senha antiga" {
	printf 'mantemesta\nmantemesta\n' | "$NPASS" insert personal email/keep
	printf 'N\n' | "$NPASS" update personal email/keep
	run "$NPASS" show personal email/keep
	[ "$output" = "mantemesta" ]
}

# --- update: --provide ---------------------------------------------------

@test "update --provide troca por senha digitada preservando resto do blob" {
	printf 'velha\nvelha\n' | "$NPASS" insert personal email/p
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal email/p
	printf 'y\nnovaSenha123\nnovaSenha123\n' | "$NPASS" update -p personal email/p
	run "$NPASS" show personal email/p
	[[ "$output" == *"novaSenha123"* ]]
	[[ "$output" == *"otpauth://"* ]]
	[[ "$output" != *"velha"* ]]
}

# --- update: --multiline --------------------------------------------------

@test "update --multiline substitui o conteudo inteiro" {
	printf 'linha1\nlinha1\n' | "$NPASS" insert personal notes/m
	printf 'novaLinha1\nnovaLinha2\n' | "$NPASS" update -f -m personal notes/m
	run "$NPASS" show personal notes/m
	[ "$output" = $'novaLinha1\nnovaLinha2' ]
}

# --- update: include/exclude ----------------------------------------------

@test "update --exclude pula entradas cuja senha antiga casa o regex" {
	printf 'skip-me\nskip-me\n' | "$NPASS" insert personal a/one
	printf 'change-me\nchange-me\n' | "$NPASS" insert personal a/two
	printf 'y\ny\n' | "$NPASS" update -f -e '^skip' -l 12 personal 'a/'
	run "$NPASS" show personal a/one
	[ "$output" = "skip-me" ]
	run "$NPASS" show personal a/two
	[ "${#output}" -eq 12 ]
}

@test "update --include so atualiza entradas cuja senha antiga casa o regex" {
	printf 'target-x\ntarget-x\n' | "$NPASS" insert personal b/one
	printf 'other-y\nother-y\n' | "$NPASS" insert personal b/two
	printf 'y\n' | "$NPASS" update -f -i '^target' -l 12 personal 'b/'
	run "$NPASS" show personal b/one
	[ "${#output}" -eq 12 ]
	run "$NPASS" show personal b/two
	[ "$output" = "other-y" ]
}

# --- update: -E (edit) ignora as demais opcoes ---------------------------

@test "update -E chama o editor e ignora confirmacao/geracao" {
	printf 'original\noriginal\n' | "$NPASS" insert personal e/one
	printf 'echo editado > "$1"' > "$BATS_TEST_TMPDIR/ed.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed.sh"
	EDITOR="$BATS_TEST_TMPDIR/ed.sh" run "$NPASS" update -E personal e/one
	[ "$status" -eq 0 ]
	run "$NPASS" show personal e/one
	[ "$output" = "editado" ]
}

# --- update: expansao de prefixo -----------------------------------------

@test "update com prefixo de diretorio atualiza todas as entradas sob ele" {
	printf 'p1\np1\n' | "$NPASS" insert personal grp/x
	printf 'p2\np2\n' | "$NPASS" insert personal grp/y
	printf 'p3\np3\n' | "$NPASS" insert personal outro/z
	printf 'y\ny\n' | "$NPASS" update -f -l 9 personal 'grp/'
	run "$NPASS" show personal grp/x
	[ "${#output}" -eq 9 ]
	run "$NPASS" show personal grp/y
	[ "${#output}" -eq 9 ]
	run "$NPASS" show personal outro/z
	[ "$output" = "p3" ]
}
