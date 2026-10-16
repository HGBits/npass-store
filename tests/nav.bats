#!/usr/bin/env bats
# Navegacao contextual de backup no show renderizado (lib/16-view.bash): links
# npass:// CALCULADOS na exibicao, nunca gravados na entrada. Glow falso (cat).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	printf '#!/bin/bash\ncat\n' >"$BATS_TEST_TMPDIR/glow"
	chmod +x "$BATS_TEST_TMPDIR/glow"
	export NPASS_GLOW="$BATS_TEST_TMPDIR/glow"
	export NPASS_TERMINAL="$BATS_TEST_TMPDIR/nunca-existe-terminal"
	unset NPASS_SHOW_RENDER
	"$NPASS" init HG "$FPR" >/dev/null
}

put() { printf '%s\0%s\0' "$1" "$2" | "$NPASS" insert --batch -f HG >/dev/null; }
mk() { printf 'x\nx\n' | "$NPASS" insert HG "$1" >/dev/null; }
bk() { printf 'b1\nb1\n' | "$NPASS" backup -n 1 HG "$1" >/dev/null; }
view() { "$NPASS" show --render HG "$1"; }

# --- entrada principal -> backup -----------------------------------------------------------------

@test "entrada com backup mostra 'Backup: [nome](npass://ID/caminho do arquivo de dados)' logo apos o titulo" {
	mk QWAP/Asyx
	bk QWAP/Asyx
	run view QWAP/Asyx
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[ "$status" -eq 0 ]
	[ "${L[0]}" = "# QWAP/Asyx" ]
	[ "${L[1]}" = "" ]
	[ "${L[2]}" = "Backup: [Asyx](npass://HG/QWAP/Asyx/Backup-Asyx.dados.md)" ]
	[ "${L[3]}" = "" ]
	[ "${L[4]}" = "## Senha" ]
}

@test "entrada sem backup nao tem linha Backup:" {
	mk QWAP/Asyx
	run view QWAP/Asyx
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" != *"Backup:"* ]]
	[ "${L[2]}" = "## Senha" ]
}

@test "o link e CALCULADO: o documento gravado e o show --raw nao mudam, antes e depois do backup" {
	mk a/x
	local antes; antes="$("$NPASS" show --raw HG a/x)"
	bk a/x
	[ "$("$NPASS" show --raw HG a/x)" = "$antes" ]
	[ "$("$NPASS" show HG a/x)" = "$antes" ]
	[[ "$("$NPASS" get all HG a/x)" != *"npass://"* ]]
}

@test "so o par completo conta: so ponteiro, so dados, stems diferentes ou entrada do usuario nao geram link" {
	mk a/x
	put a/x/Backup-so.md $'<!-- npass:backup-index v1 -->\n- arquivo: Backup-so.dados.md'
	put a/x/Backup-outro.dados.md $'<!-- npass:backup-data v1 -->\n## Backup 1\nz'
	put a/x/Backup-p.md $'<!-- npass:backup-index v1 -->'
	put a/x/Backup-q.dados.md $'<!-- npass:backup-data v1 -->'
	run view a/x
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" != *"Backup:"* ]]
}

@test "dois pares: lista os dois, em ordem" {
	mk a/x
	local i d
	for i in b a; do
		put "a/x/Backup-$i.md" $'<!-- npass:backup-index v1 -->'
		put "a/x/Backup-$i.dados.md" $'<!-- npass:backup-data v1 -->\n## Backup 1\nz'
	done
	run view a/x
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[ "${L[2]}" = "Backup: [a](npass://HG/a/x/Backup-a.dados.md), [b](npass://HG/a/x/Backup-b.dados.md)" ]
}

@test "so anexos DIRETOS da entrada: um par num nivel abaixo nao aparece" {
	mk a/x
	put a/x/sub/Backup-z.md $'<!-- npass:backup-index v1 -->'
	put a/x/sub/Backup-z.dados.md $'<!-- npass:backup-data v1 -->\n## Backup 1\nz'
	# o glob Backup-*.md atravessa "/": este par aninhado SO e barrado pelo teste de nivel
	put a/x/Backup-d/y.md $'<!-- npass:backup-index v1 -->'
	put a/x/Backup-d/y.dados.md $'<!-- npass:backup-data v1 -->\n## Backup 1\nz'
	run view a/x
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" != *"Backup:"* ]]
}

@test "depois de um mv que renomeia a entrada: texto = nome do anexo, URL = caminho novo (nunca velho)" {
	mk a/gmail
	bk a/gmail
	"$NPASS" mv HG a/gmail a/google
	run view a/google
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[ "${L[2]}" = "Backup: [gmail](npass://HG/a/google/Backup-gmail.dados.md)" ]
	[[ "$output" != *"a/gmail/"* ]]
}

@test "nome com espaco, acento, # e ? vira %XX na URL; markdown no texto do link e escapado" {
	mk 'p a/ção#1?x*y'
	bk 'p a/ção#1?x*y'
	run view 'p a/ção#1?x*y'
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" == *'Backup: [ção\#1?x\*y](npass://HG/p%20a/%C3%A7%C3%A3o%231%3Fx%2Ay/Backup-%C3%A7%C3%A3o%231%3Fx%2Ay.dados.md)'* ]]
}

# --- anexo -> entrada ------------------------------------------------------------------------------

@test "arquivo de dados e ponteiro mostram 'Entrada: [nome](url)'; o ponteiro liga ao arquivo de dados" {
	mk QWAP/Asyx
	bk QWAP/Asyx
	run view QWAP/Asyx/Backup-Asyx.dados.md
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[ "${L[2]}" = "Entrada: [Asyx](npass://HG/QWAP/Asyx)" ]
	run view QWAP/Asyx/Backup-Asyx.md
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[ "${L[2]}" = "Entrada: [Asyx](npass://HG/QWAP/Asyx)" ]
	[[ "$output" == *"- **arquivo**: [Backup-Asyx.dados.md](npass://HG/QWAP/Asyx/Backup-Asyx.dados.md)"* ]]
	[[ "$output" == *'- **quantidade**: ` 1 `'* ]]
}

@test "anexo orfao (sem a entrada principal): 'Entrada: (nao encontrada)', sem link" {
	put a/x/Backup-x.md $'<!-- npass:backup-index v1 -->\n- arquivo: Backup-x.dados.md'
	run view a/x/Backup-x.md
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" == *"Entrada: *(não encontrada)*"* ]]
	[[ "$output" != *"Entrada: ["* ]]
}

@test "o campo arquivo so vira link se for um nome Backup-*.dados.md simples (sem barra, sem ..)" {
	mk a/x
	put a/x/Backup-x.md $'<!-- npass:backup-index v1 -->\n- arquivo: ../../etc/passwd\n- criado: 2026-01-01'
	run view a/x/Backup-x.md
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" != *"npass://HG/a/x/../"* ]]
	[[ "$output" != *"](npass://HG/a/etc"* ]]
	[[ "$output" == *'- **arquivo**: ` ../../etc/passwd `'* ]]
}

# --- os links funcionam de ponta a ponta -------------------------------------------------------------

@test "seguir os links: entrada -> backup (open) -> entrada, com as senhas de backup so no destino" {
	mk QWAP/Asyx
	printf 'codigo-secreto-1\ncodigo-secreto-1\n' | "$NPASS" backup -n 1 HG QWAP/Asyx >/dev/null
	run view QWAP/Asyx
	mapfile -t L <<<"$output"   # sem colapsar linhas em branco (o `lines` do bats colapsa)
	[[ "$output" != *"codigo-secreto-1"* ]]
	local url; url="$(grep -o 'npass://[^)]*' <<<"$output" | head -n1)"
	[ "$url" = "npass://HG/QWAP/Asyx/Backup-Asyx.dados.md" ]
	NPASS_OPEN_CONFIRM=0 NPASS_SHOW_RENDER=always run "$NPASS" open --here "$url"
	[ "$status" -eq 0 ]
	[[ "$output" == *"codigo-secreto-1"* ]]
	local back; back="$(grep -o 'npass://[^)]*' <<<"$output" | head -n1)"
	[ "$back" = "npass://HG/QWAP/Asyx" ]
	NPASS_OPEN_CONFIRM=0 NPASS_SHOW_RENDER=always run "$NPASS" open --here "$back"
	[[ "$output" == *"## Senha"* ]]
	[[ "$output" == *"Backup: [Asyx]"* ]]
}

@test "todo link gerado e aceito pelo parser do open (nomes dificeis)" {
	local n
	for n in 'a b/c d' 'ção/日本語' 'x#y/z?w' '100%/ok' 'q"u\o'; do
		mk "$n"
		bk "$n"
		run view "$n"
		mapfile -t L <<<"$output"
		local url; url="$(grep -o 'npass://[^ ]*' <<<"${L[2]}" | sed 's/)$//; s/).*//' | head -n1)"
		NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here "$url"
		[ "$status" -eq 0 ]
	done
}

@test "a navegacao tambem aparece no open em terminal e nao aparece fora do modo renderizado" {
	mk a/x
	bk a/x
	run "$NPASS" show HG a/x
	[[ "$output" != *"npass://"* ]]
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here npass://HG/a/x
	[[ "$output" != *"npass://"* ]]   # sem tty o show e cru: sem links
}
