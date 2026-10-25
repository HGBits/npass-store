#!/usr/bin/env bats
# npass pin: PIN numerico em dois modos explicitamente separados (--password / --field).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$PROJECT_DIR/bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	unset NPASS_PIN_LENGTH
	"$NPASS" init HG "$FPR" >/dev/null
	# clipboard falso (wl-copy grava o stdin num arquivo)
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CLIPFILE="$BATS_TEST_TMPDIR/clip.out"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\n[[ "$1" == "--clear" ]] && exit 0\ncat > "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-copy"
	printf '#!/bin/bash\ncat "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-paste"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" WAYLAND_DISPLAY=wayland-test NPASS_CLIP_TIME=5
}

teardown() { pkill -f "sleep 5$" 2>/dev/null || true; }

# O PIN vai para o clipboard por padrao (nao para o stdout): run_pin roda o pin
# e deixa em $output o que foi copiado (o clipboard falso grava o stdin num arquivo).
run_pin() {
	run bash -c "'$NPASS' pin $* 2>/dev/null"
	local st="$status"
	sleep 0.3
	output="$(cat "$CLIPFILE" 2>/dev/null)"
	status="$st"
}

# entrada com senha, campos e notas (como a que o import produz), em md1
NOTAS_PIN=$'\n\n## Notas\nnota do usuario\nsegunda linha'
mkentry() {
	{ md1_doc 'S3nhaF0rte!' 'login: eu@x.com' 'url: https://banco.x'; printf '%s\n' "$NOTAS_PIN"; } >"$BATS_TEST_TMPDIR/corpo"
	printf '#!/bin/bash\ncp "%s" "$1"\n' "$BATS_TEST_TMPDIR/corpo" >"$BATS_TEST_TMPDIR/ed.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed.sh"
	printf 'x\nx\n' | "$NPASS" insert -f HG "${1:-banco/app}" >/dev/null
	EDITOR="$BATS_TEST_TMPDIR/ed.sh" "$NPASS" edit HG "${1:-banco/app}" >/dev/null
}

# --- o modo e obrigatorio e os dois sao exclusivos --------------------------------------

@test "sem --password nem --field: erro citando os dois modos, nada e gravado" {
	run "$NPASS" pin HG banco/app
	[ "$status" -ne 0 ]
	[[ "$output" == *"--password"* ]]
	[[ "$output" == *"--field"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "--password e --field juntos sao recusados, em qualquer ordem" {
	run "$NPASS" pin --password --field HG banco/app
	[ "$status" -ne 0 ]
	[[ "$output" == *"exclusivos"* ]]
	run "$NPASS" pin --field --password HG banco/app
	[ "$status" -ne 0 ]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "NPASS_LANG=en: a mensagem do modo obrigatorio sai em ingles" {
	NPASS_LANG=en run "$NPASS" pin HG banco/app
	[[ "$output" == *"choose the PIN mode"* ]]
}

@test "sem ID/caminho mostra uso; identidade inexistente falha; caminho com .. e recusado" {
	run "$NPASS" pin --password
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
	run "$NPASS" pin --password NAOEXISTE a/b
	[ "$status" -ne 0 ]
	run "$NPASS" pin --password HG ../fuga
	[ "$status" -ne 0 ]
}

# --- --password: o PIN e a senha ------------------------------------------------------------

@test "--password em entrada nova: a senha do cofre E o PIN (6 digitos por padrao), em md1" {
	run_pin --password HG cartao/debito
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]{6}$ ]]
	[ "$("$NPASS" get HG cartao/debito)" = "$output" ]
	[ "$("$NPASS" show HG cartao/debito)" = "$(md1_doc "$output")" ]
}

@test "digitos: 4 a 32 aceitos; 3, 33, 0, abc, -1 e 5.5 recusados" {
	local n
	for n in 4 8 32; do
		run_pin --password -f HG a/b $n
		[ "$status" -eq 0 ]
		[ "${#output}" -eq "$n" ]
	done
	for n in 3 33 0 abc -1 5.5; do
		run "$NPASS" pin --password -f HG a/b "$n"
		[ "$status" -ne 0 ]
		[[ "$output" == *"número de dígitos inválido"* ]]
	done
}

@test "NPASS_PIN_LENGTH muda o padrao, o argumento vence, valor invalido e recusado" {
	NPASS_PIN_LENGTH=9 run_pin --password -f HG a/b
	[ "${#output}" -eq 9 ]
	NPASS_PIN_LENGTH=9 run_pin --password -f HG a/b 5
	[ "${#output}" -eq 5 ]
	NPASS_PIN_LENGTH=2 run "$NPASS" pin --password -f HG a/b
	[ "$status" -ne 0 ]
}

@test "--password em entrada existente: N cancela e mantem; y e -f substituem a entrada inteira" {
	mkentry
	run bash -c "printf 'n\n' | '$NPASS' pin --password HG banco/app"
	[ "$status" -ne 0 ]
	[ "$("$NPASS" get HG banco/app)" = "S3nhaF0rte!" ]
	run bash -c "printf 'y\n' | '$NPASS' pin --password HG banco/app 2>/dev/null"
	[ "$status" -eq 0 ]
	sleep 0.3
	[ "$("$NPASS" show HG banco/app)" = "$(md1_doc "$(cat "$CLIPFILE")")" ]
	mkentry
	run_pin --password -f HG banco/app
	[ "$("$NPASS" show HG banco/app)" = "$(md1_doc "$output")" ]
}

@test "--password --in-place troca so a senha: login, url e notas ficam" {
	mkentry
	run_pin --password --in-place HG banco/app
	[ "$status" -eq 0 ]
	local pin="$output"
	run "$NPASS" show HG banco/app
	[ "$output" = "$(md1_doc "$pin" 'login: eu@x.com' 'url: https://banco.x')$NOTAS_PIN" ]
}

@test "--password nunca escreve um campo pin: (os modos nao se misturam)" {
	mkentry
	"$NPASS" pin --password --in-place HG banco/app >/dev/null 2>&1
	run "$NPASS" show HG banco/app
	[[ "$output" != *"- pin:"* ]]
}

# --- --field: o PIN e um campo independente ---------------------------------------------------------

@test "--field exige entrada existente: caminho errado nao cria entrada orfa" {
	run "$NPASS" pin --field HG typo/banco
	[ "$status" -ne 0 ]
	[[ "$output" == *"não existe"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "--field acrescenta '- pin:' ao fim dos campos, antes das notas, sem tocar em mais nada" {
	mkentry
	run_pin --field HG banco/app 8
	[ "$status" -eq 0 ]
	local pin="$output"
	[[ "$pin" =~ ^[0-9]{8}$ ]]
	run "$NPASS" show HG banco/app
	[ "$output" = "$(md1_doc 'S3nhaF0rte!' 'login: eu@x.com' 'url: https://banco.x' "pin: $pin")$NOTAS_PIN" ]
}

@test "--field em entrada so com senha, ou sem notas: cria/acrescenta o bloco de campos" {
	printf 'so-senha\nso-senha\n' | "$NPASS" insert HG a/um >/dev/null
	"$NPASS" pin --field HG a/um >/dev/null 2>&1
	run "$NPASS" show HG a/um
	[[ "$output" =~ ^$'<!-- npass:md1 -->\n## Senha\nso-senha\n\n## Campos\n- pin: '[0-9]{6}$ ]]
	md1_doc senha 'login: x' 'url: y' >"$BATS_TEST_TMPDIR/doc2"
	printf '#!/bin/bash\ncp "%s" "$1"\n' "$BATS_TEST_TMPDIR/doc2" >"$BATS_TEST_TMPDIR/ed2.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed2.sh"
	printf 'x\nx\n' | "$NPASS" insert HG a/dois >/dev/null
	EDITOR="$BATS_TEST_TMPDIR/ed2.sh" "$NPASS" edit HG a/dois >/dev/null
	"$NPASS" pin --field HG a/dois >/dev/null 2>&1
	run "$NPASS" show HG a/dois
	[[ "$output" =~ ^$'<!-- npass:md1 -->\n## Senha\nsenha\n\n## Campos\n- login: x\n- url: y\n- pin: '[0-9]{6}$ ]]
}

@test "--field: clip padrao continua copiando a SENHA e 'clip pin' copia o PIN" {
	mkentry
	run_pin --field HG banco/app
	[ "$status" -eq 0 ]
	local pin="$output"
	[[ "$pin" =~ ^[0-9]{6}$ ]]
	"$NPASS" clip HG banco/app >/dev/null
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "S3nhaF0rte!" ]
	"$NPASS" clip pin HG banco/app >/dev/null
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "$pin" ]
}

@test "--field com pin: ja existente: N cancela; y e -f substituem; continua UMA linha pin" {
	mkentry
	"$NPASS" pin --field HG banco/app >/dev/null 2>&1
	local antes; antes="$("$NPASS" show HG banco/app)"
	run bash -c "printf 'n\n' | '$NPASS' pin --field HG banco/app"
	[ "$status" -ne 0 ]
	[ "$("$NPASS" show HG banco/app)" = "$antes" ]
	run bash -c "printf 'y\n' | '$NPASS' pin --field HG banco/app 2>/dev/null"
	[ "$status" -eq 0 ]
	[ "$("$NPASS" show HG banco/app)" != "$antes" ]
	"$NPASS" pin --field -f HG banco/app >/dev/null 2>&1
	[ "$("$NPASS" show HG banco/app | grep -ci '^- pin *:')" -eq 1 ]
	[ "$("$NPASS" get HG banco/app)" = "S3nhaF0rte!" ]
}

@test "--field reconhece '- PIN :' (caixa e espacos) e troca so a PRIMEIRA ocorrencia" {
	md1_doc senha 'PIN : 1111' 'login: x' 'pin: 2222' >"$BATS_TEST_TMPDIR/doc3"
	printf '#!/bin/bash\ncp "%s" "$1"\n' "$BATS_TEST_TMPDIR/doc3" >"$BATS_TEST_TMPDIR/ed3.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed3.sh"
	printf 'x\nx\n' | "$NPASS" insert HG a/b >/dev/null
	EDITOR="$BATS_TEST_TMPDIR/ed3.sh" "$NPASS" edit HG a/b >/dev/null
	run_pin --field -f HG a/b
	local pin="$output"
	run "$NPASS" show HG a/b
	[ "$output" = "$(md1_doc senha "pin: $pin" 'login: x' 'pin: 2222')" ]
}

@test "uma senha que parece '- pin: ...' ou '## Campos' e so a senha, nao um campo nem um cabecalho" {
	printf 'pin: abc\npin: abc\n' | "$NPASS" insert HG a/b >/dev/null
	printf '## Campos\n## Campos\n' | "$NPASS" insert HG a/c >/dev/null
	"$NPASS" pin --field HG a/b >/dev/null 2>&1
	"$NPASS" pin --field HG a/c >/dev/null 2>&1
	[ "$("$NPASS" get HG a/b)" = "pin: abc" ]
	[ "$("$NPASS" get HG a/c)" = "## Campos" ]
	run "$NPASS" show HG a/b
	[[ "$output" =~ $'\n- pin: '[0-9]{6}$ ]]
	run "$NPASS" show HG a/c
	[[ "$output" =~ $'\n- pin: '[0-9]{6}$ ]]
}

@test "--field --in-place e recusado (o modo field ja altera so o campo)" {
	mkentry
	run "$NPASS" pin --field --in-place HG banco/app
	[ "$status" -ne 0 ]
	[[ "$output" == *"--in-place só vale com --password"* ]]
}

@test "entrada fora de md1: --field e --password --in-place recusam e nao alteram nada" {
	npass_test_raw HG banco/velho $'senha-velha\nlogin: x'
	local antes; antes="$("$NPASS" show HG banco/velho)"
	run "$NPASS" pin --field HG banco/velho
	[ "$status" -ne 0 ]
	[[ "$output" == *"não está no formato md1"* ]]
	run "$NPASS" pin --password --in-place HG banco/velho
	[ "$status" -ne 0 ]
	[ "$("$NPASS" show HG banco/velho)" = "$antes" ]
}

# --- saida ------------------------------------------------------------------------------------------------

@test "PIN e copiado para o clipboard por padrao e nao aparece no stdout" {
    run bash -c "'$NPASS' pin --password HG a/b 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    sleep 0.3
    [[ "$(cat "$CLIPFILE")" =~ ^[0-9]{6}$ ]]
}

@test "--field copia o PIN para o clipboard por padrao" {
    mkentry

    run bash -c "'$NPASS' pin --field HG banco/app 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    sleep 0.3
    [[ "$(cat "$CLIPFILE")" =~ ^[0-9]{6}$ ]]
}

@test "-c copia o PIN para o clipboard e nao o imprime" {
	run bash -c "'$NPASS' pin --password -c HG a/b 2>/dev/null"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "$("$NPASS" get HG a/b)" ]
}

@test "commit automatico generico (sem caminho logico)" {
	"$NPASS" pin --password HG Servico/Secreto >/dev/null 2>&1
	run git -C "$NPASS_STORE" log -1 --format=%s
	[ "$output" = "pin: HG" ]
	run git -C "$NPASS_STORE" log -p --all
	[[ "$output" != *"Servico"* ]]
}

@test "help lista o comando pin" {
	run "$NPASS" help gerar pin
	[[ "$output" == *"pin (--password|--field)"* ]]
}

# --- entrada ilegivel: nunca sobrescrever dados que nao foram vistos ---------------------------------------

corromper() { printf 'lixo-nao-decifravel' >"$(ls "$NPASS_STORE"/HG/blobs/*.gpg | head -1)"; }
hash_blob() { sha256sum "$(ls "$NPASS_STORE"/HG/blobs/*.gpg | head -1)" | cut -d' ' -f1; }

@test "entrada ilegivel: --field e --password --in-place param sem alterar nada" {
	mkentry
	corromper
	local antes; antes="$(hash_blob)"
	run "$NPASS" pin --field HG banco/app
	[ "$status" -ne 0 ]
	[[ "$output" == *"não pôde ser decifrada"* ]]
	[ "$(hash_blob)" = "$antes" ]
	run "$NPASS" pin --password --in-place HG banco/app
	[ "$status" -ne 0 ]
	[ "$(hash_blob)" = "$antes" ]
}

@test "entrada ilegivel: --password sem -f pergunta (EOF = nao) e mantem; so -f sobrescreve" {
	mkentry
	corromper
	local antes; antes="$(hash_blob)"
	run bash -c "'$NPASS' pin --password HG banco/app </dev/null"
	[ "$status" -ne 0 ]
	[ "$(hash_blob)" = "$antes" ]
	run_pin --password -f HG banco/app
	[ "$status" -eq 0 ]
	[ "$("$NPASS" get HG banco/app)" = "$output" ]
}

# --- geracao dos digitos --------------------------------------------------------------------------------------

@test "npass_pin_digits preserva zeros a esquerda (o PIN e texto, nunca numero)" {
	source <(sed -n '/^npass_pin_digits()/,/^}/p' "$PROJECT_DIR/lib/08-pin.bash")
	tr() { printf '000123456789'; }   # no lugar do tr real: 12 digitos, comecando por zeros
	run npass_pin_digits 6
	[ "$status" -eq 0 ]
	[ "$output" = "000123" ]
	run npass_pin_digits 12
	[ "$output" = "000123456789" ]
}

@test "npass_pin_digits recusa quando /dev/urandom nao entrega digitos suficientes" {
	source <(sed -n '/^npass_pin_digits()/,/^}/p' "$PROJECT_DIR/lib/08-pin.bash")
	npass_t() { echo "ENTROPIA"; }
	npass_die() { echo "$*"; exit 1; }
	tr() { printf '12'; }
	run npass_pin_digits 6
	[ "$status" -ne 0 ]
	[[ "$output" == *"ENTROPIA"* ]]
}

@test "os 10 digitos aparecem nos PINs gerados e so existem digitos" {
	source <(sed -n '/^npass_pin_digits()/,/^}/p' "$PROJECT_DIR/lib/08-pin.bash")
	local all="" i
	for i in $(seq 1 50); do all+="$(npass_pin_digits 4)"; done
	[[ "$all" =~ ^[0-9]{200}$ ]]
	local d
	for d in 0 1 2 3 4 5 6 7 8 9; do [[ "$all" == *"$d"* ]]; done
}
