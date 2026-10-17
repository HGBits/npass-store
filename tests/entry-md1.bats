#!/usr/bin/env bats
# Formato md1: o conteudo de toda entrada (lib/14-entry.bash) e o comando `get`.
# Cobre o contrato do formato, a preservacao de linhas desconhecidas, a recusa
# de entradas no formato antigo em TODOS os comandos que leem o conteudo e a
# validacao do que entra por insert --batch / edit.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$PROJECT_DIR/bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	"$NPASS" init HG "$FPR" >/dev/null
	# clipboard falso
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CLIPFILE="$BATS_TEST_TMPDIR/clip.out"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\n[[ "$1" == "--clear" ]] && exit 0\ncat > "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-copy"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" WAYLAND_DISPLAY=wayland-test NPASS_CLIP_TIME=5
}

teardown() { pkill -f "sleep 5$" 2>/dev/null || true; }

# put CAMINHO DOC: grava um documento md1 pronto (via insert --batch)
put() { printf '%s\0%s\0' "$1" "$2" | "$NPASS" insert --batch -f HG >/dev/null; }

# --- o que o npass escreve ----------------------------------------------------------------

@test "insert grava o documento md1 minimo: marcador, ## Senha e a senha" {
	printf 'hunter2\nhunter2\n' | "$NPASS" insert HG a/x >/dev/null
	run "$NPASS" show HG a/x
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\nhunter2' ]
}

@test "generate grava md1 e --in-place so troca a senha" {
	"$NPASS" generate -f HG a/g 14 >/dev/null
	run "$NPASS" show HG a/g
	[ "${lines[0]}" = "<!-- npass:md1 -->" ]
	[ "${lines[1]}" = "## Senha" ]
	[ "${#lines[2]}" -eq 14 ]
	put a/h "$(md1_doc velha 'login: eu')"$'\n\n## Notas\nnota'
	"$NPASS" generate -f --in-place HG a/h 10 >/dev/null
	run "$NPASS" show HG a/h
	[ "${#lines[2]}" -eq 10 ]
	[ "$output" = "$(md1_doc "${lines[2]}" 'login: eu')"$'\n\n## Notas\nnota' ]
}

@test "senhas que parecem estrutura sao guardadas e lidas por posicao, sem tirar nada" {
	local pw
	for pw in '## Senha' '## Campos' '## Notas' '- login: x' '<!-- npass:md1 -->' '# titulo' 'a: b'; do
		printf '%s\n%s\n' "$pw" "$pw" | "$NPASS" insert -f HG a/esp >/dev/null
		[ "$("$NPASS" get HG a/esp)" = "$pw" ]
		run "$NPASS" show HG a/esp
		[ "$output" = $'<!-- npass:md1 -->\n## Senha\n'"$pw" ]
	done
}

# --- get ----------------------------------------------------------------------------------

@test "get: senha por padrao; pass/senha equivalentes; all = documento inteiro" {
	put a/x "$(md1_doc segredo 'login: eu@x.com' 'url: https://x')"
	[ "$("$NPASS" get HG a/x)" = "segredo" ]
	[ "$("$NPASS" get pass HG a/x)" = "segredo" ]
	[ "$("$NPASS" get senha HG a/x)" = "segredo" ]
	[ "$("$NPASS" get all HG a/x)" = "$(md1_doc segredo 'login: eu@x.com' 'url: https://x')" ]
}

@test "get CAMPO: sem diferenciar caixa, chave exata vence prefixo, prefixo unico funciona" {
	put a/x "$(md1_doc segredo 'Email: nat@x.com' 'email-alias: a@x.com' 'user: natty')"
	[ "$("$NPASS" get USER HG a/x)" = "natty" ]
	[ "$("$NPASS" get email HG a/x)" = "nat@x.com" ]
	[ "$("$NPASS" get email-a HG a/x)" = "a@x.com" ]
}

@test "get: campo inexistente lista so as chaves; senha vazia e campo vazio falham" {
	put a/x "$(md1_doc segredo 'email: nat@x.com' 'vazio:')"
	run "$NPASS" get telefone HG a/x
	[ "$status" -ne 0 ]
	[[ "$output" == *"email"* ]]
	[[ "$output" != *"nat@x.com"* ]]
	run "$NPASS" get vazio HG a/x
	[ "$status" -ne 0 ]
	put a/sem "$(md1_doc '' 'login: x')"
	run "$NPASS" get HG a/sem
	[ "$status" -ne 0 ]
}

@test "get: numero de argumentos invalido mostra uso" {
	run "$NPASS" get HG
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
}

@test "clip e get leem a mesma coisa" {
	put a/x "$(md1_doc segredo 'login: eu')"
	"$NPASS" clip login HG a/x >/dev/null
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "$("$NPASS" get login HG a/x)" ]
}

@test "help lista o get" {
	run "$NPASS" help entradas ver
	[[ "$output" == *"get [CAMPO] ID DIR/PASS"* ]]
}

# --- estrutura: o que se preserva e o que se recusa -----------------------------------------

@test "linhas desconhecidas em Campos/OTP e notas com cara de cabecalho sobrevivem a uma reescrita" {
	local doc
	doc=$'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- login: x\ntexto solto no bloco\n- url: y\n\n## OTP\notpauth://totp/a?secret=ABC\n\n## Notas\nl1\n## Campos\n- falso: campo\n\nl4'
	put a/x "$doc"
	"$NPASS" pin --field -f HG a/x >/dev/null 2>&1
	run "$NPASS" show HG a/x
	[[ "$output" == *$'- login: x\ntexto solto no bloco\n- url: y\n- pin: '* ]]
	[[ "$output" == *$'\n\n## OTP\notpauth://totp/a?secret=ABC\n\n## Notas\nl1\n## Campos\n- falso: campo\n\nl4' ]]
	[ "$("$NPASS" get HG a/x)" = "pw" ]
	run "$NPASS" get falso HG a/x
	[ "$status" -ne 0 ]
}

@test "uma nota que parece campo nao vira campo" {
	put a/x "$(md1_doc pw)"$'\n\n## Notas\nlogin: so-uma-nota'
	run "$NPASS" get login HG a/x
	[ "$status" -ne 0 ]
}

@test "insert --batch recusa estrutura invalida: fora de ordem, secao repetida, texto solto, sem Senha" {
	local bad
	bad=(
		$'<!-- npass:md1 -->\n## Senha\npw\n\n## OTP\notpauth://totp/a?secret=ABC\n\n## Campos\n- a: b'
		$'<!-- npass:md1 -->\n## Senha\npw\n\n## Senha\noutra'
		$'<!-- npass:md1 -->\n## Senha\npw\nlixo solto depois da senha'
		$'<!-- npass:md1 -->\n## Campos\n- a: b'
		$'<!-- npass:md1 -->'
		$'<!-- npass:md1 -->\nsolto antes de tudo\n## Senha\npw'
	)
	local i
	for i in "${!bad[@]}"; do
		run bash -c "printf 'b/%s\\0%s\\0' '$i' \"\$1\" | '$NPASS' insert --batch HG" _ "${bad[i]}"
		[ "$status" -ne 0 ]
	done
	run "$NPASS" tree HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "entrada com marcador mas estrutura invalida (ja gravada): get e pin dizem 'estrutura invalida'" {
	npass_test_legacy HG a/x $'<!-- npass:md1 -->\n## Senha\npw\nlixo'
	run "$NPASS" get HG a/x
	[ "$status" -ne 0 ]
	[[ "$output" == *"estrutura é inválida"* ]]
	run "$NPASS" pin --field HG a/x
	[ "$status" -ne 0 ]
	[[ "$output" == *"estrutura é inválida"* ]]
}

# --- formato antigo: recusado em todo comando que le o conteudo -----------------------------

@test "formato antigo: get, clip, otp, generate --in-place e edit recusam, mandam converter e nao alteram" {
	npass_test_legacy HG a/velha $'senha-velha\nlogin: x\notpauth://totp/a?secret=JBSWY3DPEHPK3PXP'
	local antes; antes="$("$NPASS" show HG a/velha)"
	local cmd
	for cmd in "get HG a/velha" "get login HG a/velha" "clip HG a/velha" "otp HG a/velha" "otp uri HG a/velha" "generate -f --in-place HG a/velha" "edit HG a/velha"; do
		run bash -c "EDITOR=true '$NPASS' $cmd"
		[ "$status" -ne 0 ]
		[[ "$output" == *"formato antigo"* ]]
		[[ "$output" == *"npass import npass-legacy HG"* ]]
	done
	[ "$("$NPASS" show HG a/velha)" = "$antes" ]
}

@test "formato antigo: show, ls, grep, mv e rm continuam funcionando (so ler conteudo exige md1)" {
	npass_test_legacy HG a/velha 'senha-velha'
	run "$NPASS" show HG a/velha
	[ "$output" = "senha-velha" ]
	run "$NPASS" tree --flat HG
	[[ "$output" == *"a/velha"* ]]
	"$NPASS" mv HG a/velha a/nova
	run "$NPASS" show HG a/nova
	[ "$output" = "senha-velha" ]
	run "$NPASS" rm -f HG a/nova
	[ "$status" -eq 0 ]
}

@test "anexo de backup: get/clip dizem que e um anexo, nao 'formato antigo'" {
	printf 'x\nx\n' | "$NPASS" insert HG a/x >/dev/null
	printf 'b1\nb1\n' | "$NPASS" backup -n 1 HG a/x >/dev/null
	run "$NPASS" get HG a/x/Backup-x.dados.md
	[ "$status" -ne 0 ]
	[[ "$output" == *"anexo de backup"* ]]
	[[ "$output" != *"formato antigo"* ]]
}

# --- edit e update -m: so md1 entra ---------------------------------------------------------

@test "update -m e edit aceitam um documento md1 completo (campos, OTP e notas)" {
	local doc
	doc=$'<!-- npass:md1 -->\n## Senha\nnovo\n\n## Campos\n- login: l\n\n## OTP\notpauth://totp/a?secret=ABC\n\n## Notas\nn1'
	printf 'a\na\n' | "$NPASS" insert HG a/x >/dev/null
	printf '%s\n' "$doc" | "$NPASS" update -f -m HG a/x
	run "$NPASS" show HG a/x
	[ "$output" = "$doc" ]
}

# --- OTP em md1 -----------------------------------------------------------------------------

@test "otp insert em caminho novo cria entrada md1 com senha vazia e a secao OTP" {
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert HG a/so-otp >/dev/null
	run "$NPASS" show HG a/so-otp
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\n\n\n## OTP\n'"$uri" ]
}

@test "otp insert em entrada existente poe o OTP entre os campos e as notas" {
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	put a/x "$(md1_doc pw 'login: eu')"$'\n\n## Notas\nnota'
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert HG a/x >/dev/null
	run "$NPASS" show HG a/x
	[ "$output" = "$(md1_doc pw 'login: eu')"$'\n\n## OTP\n'"$uri"$'\n\n## Notas\nnota' ]
}

@test "otp insert troca a URI existente em vez de duplicar (-f)" {
	local u1="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	local u2="otpauth://totp/y?secret=JBSWY3DPEHPK3PXP"
	printf '%s\n%s\n' "$u1" "$u1" | "$NPASS" otp insert HG a/x >/dev/null
	printf '%s\n%s\n' "$u2" "$u2" | "$NPASS" otp insert -f HG a/x >/dev/null
	run "$NPASS" show HG a/x
	[[ "$output" == *"$u2"* ]]
	[[ "$output" != *"$u1"* ]]
	[ "$(grep -c 'otpauth://' <<<"$output")" -eq 1 ]
}

# --- npass-audit le md1 ---------------------------------------------------------------------

@test "audit le a senha da secao Senha: acha reuso entre entradas md1" {
	command -v python3 >/dev/null || skip "python3 ausente"
	put a/um "$(md1_doc 'Mesma-Senha-123!' 'login: x')"
	put a/dois "$(md1_doc 'Mesma-Senha-123!')"
	put a/tres "$(md1_doc 'outra-bem-diferente-9#')"
	NPASS_BIN="$NPASS" run python3 "$PROJECT_DIR/extensions/npass-audit" HG --offline
	[ "$status" -eq 1 ]   # 1 = achou problema (reuso)
	[[ "$output" == *"REUTILIZADA: a/dois, a/um"* ]]
	[[ "$output" == *"Resumo: 3 senha(s)"* ]]
	[[ "$output" == *"1 grupo(s) reutilizado(s)"* ]]
}

@test "audit: entrada no formato antigo e reportada como falha (aponta a conversao), nao lida como senha" {
	command -v python3 >/dev/null || skip "python3 ausente"
	put a/ok "$(md1_doc 'uma-senha-qualquer-1!')"
	npass_test_legacy HG a/velha 'senha-velha'
	NPASS_BIN="$NPASS" run python3 "$PROJECT_DIR/extensions/npass-audit" HG --offline
	[[ "$output" == *"a/velha"* ]]
	[[ "$output" == *"npass import npass-legacy"* ]]
	[[ "$output" == *"Resumo: 1 senha(s)"* ]]
	[[ "$output" != *"Traceback"* ]]
}
