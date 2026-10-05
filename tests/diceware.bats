#!/usr/bin/env bats
# npass diceware (com ALTURAS) e npass memorable (sem indice), listas da EFF.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$PROJECT_DIR/bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	unset NPASS_DICEWARE_SEP NPASS_WORDLIST NPASS_WORDLIST_SRC
	"$NPASS" init HG "$FPR" >/dev/null
	WL="$NPASS_STORE/wordlist.txt"
	# clipboard falso (wl-copy grava o stdin num arquivo)
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CLIPFILE="$BATS_TEST_TMPDIR/clip.out"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\n[[ "$1" == "--clear" ]] && exit 0\ncat > "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-copy"
	printf '#!/bin/bash\ncat "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-paste"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" WAYLAND_DISPLAY=wayland-test NPASS_CLIP_TIME=5
}

teardown() { pkill -f "sleep 5$" 2>/dev/null || true; }

# alturas impressas pelo diceware: a linha com N numeros de 5 digitos (so 1-6)
heights() { grep -E '^ +[1-6]{5}( [1-6]{5})*$' <<<"$output" | tr -s ' ' | sed 's/^ //'; }

# palavra da secao [large] da lista do usuario para uma altura
word_of() { awk -F'\t' -v h="$1" '/^\[/{s=$0} s=="[large]" && $1==h {print $2}' "$WL"; }

# reconstroi a frase so com SEP + alturas + lista (o que o usuario faria com o papel)
rebuild() {
	local sep="$1" out="" h first=1
	shift
	for h in "$@"; do
		((first)) || out+="$sep"
		out+="$(word_of "$h")"
		first=0
	done
	printf '%s' "$out"
}

in_section() { awk -F'\t' -v w="$1" -v sec="[$2]" '/^\[/{s=$0} s==sec && $2==w {f=1} END{exit !f}' "$WL"; }

# --- a lista: onde fica e como chega la -------------------------------------------

@test "primeira vez: copia a lista para o store, identica a do repositorio, e avisa" {
	[ ! -e "$WL" ]
	run "$NPASS" diceware HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" == *"lista de palavras copiada para $WL"* ]]
	cmp "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" "$WL"
}

@test "uma lista que o usuario ja tem nunca e sobrescrita" {
	cp "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" "$WL"
	printf '# minha lista\n' >>"$WL"
	run "$NPASS" diceware HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" != *"lista de palavras copiada"* ]]
	grep -q '^# minha lista$' "$WL"
}

@test "NPASS_WORDLIST muda o caminho da lista" {
	export NPASS_WORDLIST="$BATS_TEST_TMPDIR/outra/lista.txt"
	run "$NPASS" diceware HG a/b
	[ "$status" -eq 0 ]
	[ -f "$NPASS_WORDLIST" ]
	[ ! -e "$WL" ]
}

@test "sem lista no store e sem copia para trazer: erro claro e nada gravado" {
	export NPASS_WORDLIST_SRC="$BATS_TEST_TMPDIR/nao-existe.txt"
	run "$NPASS" diceware HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"encrypts_alternatives/wordlist.txt"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "lista pequena demais e recusada (arquivo truncado ou adulterado)" {
	{ printf '[large]\n'; head -n 200 <(sed -n '/^\[large\]$/,/^\[short1\]$/p' "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" | grep -P '^[1-6]{5}\t'); } >"$WL"
	run "$NPASS" diceware HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"pequena demais"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "linhas malformadas da lista sao ignoradas, nunca usadas" {
	sed '/^\[large\]$/a 99999\tbadheight\n11111\tUPPER\n11111\ta\tb' "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" >"$WL"
	run "$NPASS" diceware HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" == *"7776 palavras"* ]]
	[[ "$output" != *"99999"* ]]
}

@test "sem a secao [large]: diceware recusa, memorable continua funcionando" {
	sed '/^\[large\]$/,/^\[short1\]$/{/^\[short1\]$/!d}' "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" >"$WL"
	run "$NPASS" diceware HG a/b
	[ "$status" -ne 0 ]
	run "$NPASS" memorable HG c/d
	[ "$status" -eq 0 ]
}

# --- diceware: alturas e recuperacao --------------------------------------------------

@test "diceware: a senha do cofre e refeita SO com as alturas, o separador e a lista" {
	run "$NPASS" diceware HG Banco/Itau
	[ "$status" -eq 0 ]
	read -r -a H <<<"$(heights)"
	[ "${#H[@]}" -eq 6 ]
	[ "$(rebuild '-' "${H[@]}")" = "$("$NPASS" show HG Banco/Itau)" ]
}

@test "diceware: a frase NAO aparece na saida, so as alturas; nada vai para o stdout" {
	run "$NPASS" diceware HG a/b
	local frase; frase="$("$NPASS" show HG a/b)"
	[[ "$output" != *"$frase"* ]]
	run bash -c "'$NPASS' diceware -f HG a/b 2>/dev/null"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "diceware: avisa que o indice E a senha e como guarda-lo" {
	run "$NPASS" diceware HG a/b
	[[ "$output" == *"ALTURAS"* ]]
	[[ "$output" == *"ATENÇÃO"* ]]
	[[ "$output" == *"É a sua senha em outra forma"* ]]
	[[ "$output" == *"scrollback"* ]]
	[[ "$output" == *"anote também"* ]]
}

@test "diceware: toda palavra da frase esta na secao [large], e o cofre guarda so a frase (uma linha)" {
	# separador ESPACO: a lista tem palavras com hifen (yo-yo, t-shirt) que um '-' confundiria
	"$NPASS" diceware -s ' ' HG a/b 12 >/dev/null 2>&1
	run "$NPASS" show HG a/b
	[ "$(wc -l <<<"$output")" -eq 1 ]
	local w n=0
	for w in $output; do
		in_section "$w" large
		n=$((n + 1))
	done
	[ "$n" -eq 12 ]
}

@test "diceware: numero de palavras padrao 6, explicito 8, e as alturas acompanham" {
	run "$NPASS" diceware HG a/b
	read -r -a H <<<"$(heights)"
	[ "${#H[@]}" -eq 6 ]
	run "$NPASS" diceware -f HG a/b 8
	read -r -a H <<<"$(heights)"
	[ "${#H[@]}" -eq 8 ]
	[ "$(rebuild '-' "${H[@]}")" = "$("$NPASS" show HG a/b)" ]
}

@test "numero de palavras fora de 4..20 ou nao numerico e recusado" {
	local n
	for n in 3 21 0 abc -1 5.5; do
		run "$NPASS" diceware -f HG a/b "$n"
		[ "$status" -ne 0 ]
		[[ "$output" == *"número de palavras inválido"* ]]
	done
	run "$NPASS" diceware -f HG a/b 4
	[ "$status" -eq 0 ]
	run "$NPASS" diceware -f HG a/b 20
	[ "$status" -eq 0 ]
}

@test "entropia mostrada e calculada sobre a lista usada (6 x log2 7776 = 77.5)" {
	run "$NPASS" diceware HG a/b
	[[ "$output" == *"7776 palavras, ~77.5 bits"* ]]
}

# --- separador ---------------------------------------------------------------------------

@test "--sep escolhe o separador, que aparece para ser anotado, e a recuperacao o usa" {
	run "$NPASS" diceware --sep '::' HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" == *'Separador: "::"'* ]]
	read -r -a H <<<"$(heights)"
	[ "$(rebuild '::' "${H[@]}")" = "$("$NPASS" show HG a/b)" ]
}

@test "separador vazio concatena as palavras" {
	run "$NPASS" diceware -s '' HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" == *"Separador: (nenhum)"* ]]
	read -r -a H <<<"$(heights)"
	[ "$(rebuild '' "${H[@]}")" = "$("$NPASS" show HG a/b)" ]
}

@test "separador: ate 3 caracteres (contados como caracteres, nao bytes); 4 ou controle e recusado" {
	run "$NPASS" diceware -f -s 'abc' HG a/b
	[ "$status" -eq 0 ]
	run "$NPASS" diceware -f -s $'\xe2\x86\x92\xe2\x86\x92\xe2\x86\x92' HG a/b
	[ "$status" -eq 0 ]
	run "$NPASS" diceware -f -s 'abcd' HG a/b
	[ "$status" -ne 0 ]
	run "$NPASS" diceware -f -s $'\xe2\x86\x92\xe2\x86\x92\xe2\x86\x92\xe2\x86\x92' HG a/b
	[ "$status" -ne 0 ]
	run "$NPASS" diceware -f -s $'\t' HG a/b
	[ "$status" -ne 0 ]
	run "$NPASS" diceware -f -s $'a\nb' HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"separador inválido"* ]]
}

@test "NPASS_DICEWARE_SEP predefine o separador; --sep vence; valor invalido cita a variavel" {
	NPASS_DICEWARE_SEP='.' run "$NPASS" memorable HG a/b
	[[ "$output" == *"."* ]]
	[[ "$("$NPASS" show HG a/b)" == *.*.*.*.*.* ]]
	NPASS_DICEWARE_SEP='.' run "$NPASS" memorable -f -s '+' HG a/b
	[[ "$("$NPASS" show HG a/b)" == *+*+*+*+*+* ]]
	NPASS_DICEWARE_SEP='muito-longo' run "$NPASS" memorable -f HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"NPASS_DICEWARE_SEP"* ]]
}

# --- memorable ----------------------------------------------------------------------------

@test "memorable: a frase sai no stdout e e a do cofre; sem alturas e sem aviso de indice" {
	run bash -c "'$NPASS' memorable HG a/b 2>/dev/null"
	[ "$status" -eq 0 ]
	[ "$output" = "$("$NPASS" show HG a/b)" ]
	run "$NPASS" memorable -f HG a/b
	[[ "$output" != *"ALTURAS"* ]]
	[[ "$output" != *"ATENÇÃO"* ]]
	[ -z "$(heights)" ]
}

@test "memorable: as palavras vem das listas short; -l escolhe short1 ou short2; lista invalida e recusada" {
	local w n
	# separador ESPACO: yo-yo existe nas listas e um '-' o partiria em duas "palavras"
	"$NPASS" memorable -f -s ' ' HG a/b 12 >/dev/null 2>&1
	n=0
	for w in $("$NPASS" show HG a/b); do
		in_section "$w" short1 || in_section "$w" short2
		n=$((n + 1))
	done
	[ "$n" -eq 12 ]
	"$NPASS" memorable -f -s ' ' -l short1 HG a/b 12 >/dev/null 2>&1
	for w in $("$NPASS" show HG a/b); do
		in_section "$w" short1
		[ "${#w}" -le 5 ]
	done
	"$NPASS" memorable -f -s ' ' --list=short2 HG a/b 12 >/dev/null 2>&1
	for w in $("$NPASS" show HG a/b); do
		in_section "$w" short2
	done
	run "$NPASS" memorable -f -l xx HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"lista inválida"* ]]
}

@test "diceware nao aceita --list (as alturas so fazem sentido para uma lista)" {
	run "$NPASS" diceware -l short1 HG a/b
	[ "$status" -ne 0 ]
	[[ "$output" == *"opção desconhecida"* ]]
}

@test "memorable: entropia sobre a uniao das duas listas curtas (2448 palavras distintas)" {
	run "$NPASS" memorable HG a/b
	[[ "$output" == *"2448 palavras distintas, ~67.5 bits"* ]]
	run "$NPASS" memorable -f -l short1 HG a/b
	[[ "$output" == *"1296 palavras distintas, ~62.0 bits"* ]]
}

# --- clipboard, sobrescrita, in-place ---------------------------------------------------------

@test "-c copia a frase; diceware ainda mostra as alturas e memorable nao imprime a frase" {
	run "$NPASS" diceware -c HG a/b
	[ "$status" -eq 0 ]
	sleep 0.3
	[ "$(cat "$CLIPFILE")" = "$("$NPASS" show HG a/b)" ]
	[ -n "$(heights)" ]
	: >"$CLIPFILE"
	run bash -c "'$NPASS' memorable -c -f HG a/b 2>/dev/null"
	sleep 0.3
	[ -z "$output" ]
	[ "$(cat "$CLIPFILE")" = "$("$NPASS" show HG a/b)" ]
}

@test "entrada existente: N cancela e mantem, y e -f sobrescrevem" {
	printf 'antiga\nantiga\n' | "$NPASS" insert HG a/b >/dev/null
	run bash -c "printf 'n\n' | '$NPASS' diceware HG a/b"
	[ "$status" -ne 0 ]
	[ "$("$NPASS" show HG a/b)" = "antiga" ]
	run bash -c "printf 'y\n' | '$NPASS' diceware HG a/b"
	[ "$status" -eq 0 ]
	[ "$("$NPASS" show HG a/b)" != "antiga" ]
	printf 'antiga\nantiga\n' | "$NPASS" insert -f HG a/b >/dev/null
	"$NPASS" memorable -f HG a/b >/dev/null 2>&1
	[ "$("$NPASS" show HG a/b)" != "antiga" ]
}

@test "--in-place troca so a primeira linha e preserva OTP e notas" {
	printf 'senha-velha\nlogin: eu\notpauth://totp/X?secret=ABCDEFGHIJKLMNOP\n' >"$BATS_TEST_TMPDIR/corpo"
	printf '#!/bin/bash\ncp "%s" "$1"\n' "$BATS_TEST_TMPDIR/corpo" >"$BATS_TEST_TMPDIR/ed.sh"
	chmod +x "$BATS_TEST_TMPDIR/ed.sh"
	printf 'x\nx\n' | "$NPASS" insert HG a/b >/dev/null
	EDITOR="$BATS_TEST_TMPDIR/ed.sh" "$NPASS" edit HG a/b >/dev/null
	run "$NPASS" diceware --in-place HG a/b
	[ "$status" -eq 0 ]
	run "$NPASS" show HG a/b
	[[ "$output" == *$'\nlogin: eu\notpauth://totp/X?secret=ABCDEFGHIJKLMNOP' ]]
	[[ "${output%%$'\n'*}" != "senha-velha" ]]
}

# --- git, ajuda, uso ----------------------------------------------------------------------------

@test "commit automatico generico (sem caminho logico) e a lista fica fora do git" {
	"$NPASS" diceware HG Servico/Secreto >/dev/null 2>&1
	run git -C "$NPASS_STORE" log -1 --format=%s
	[ "$output" = "diceware: HG" ]
	"$NPASS" memorable HG Outro/Segredo >/dev/null 2>&1
	run git -C "$NPASS_STORE" log -1 --format=%s
	[ "$output" = "memorable: HG" ]
	run git -C "$NPASS_STORE" log -p --all
	[[ "$output" != *"Servico"* ]]
	run git -C "$NPASS_STORE" ls-files
	[[ "$output" != *"wordlist.txt"* ]]
}

@test "help lista os dois comandos; sem argumentos mostra uso; identidade inexistente falha" {
	run "$NPASS" help
	[[ "$output" == *"diceware"* ]]
	[[ "$output" == *"memorable"* ]]
	run "$NPASS" diceware
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
	run "$NPASS" memorable NAOEXISTE a/b
	[ "$status" -ne 0 ]
}

# --- sorteio sem vies -----------------------------------------------------------------------------

@test "npass_rand_range: sempre dentro de [0,n) e cobre todos os valores" {
	source <(sed -n '/^npass_rand_range()/,/^}/p' "$PROJECT_DIR/lib/12-diceware.bash")
	local n i v
	for n in 1 2 6 7776; do
		for i in $(seq 1 60); do
			v="$(npass_rand_range "$n")"
			((v >= 0 && v < n))
		done
	done
	local seen=""
	for i in $(seq 1 300); do seen+="$(npass_rand_range 6) "; done
	for v in 0 1 2 3 4 5; do [[ " $seen" == *" $v "* ]]; done
}

@test "npass_rand_range: rejeita valores do bloco incompleto (sem vies de modulo)" {
	source <(sed -n '/^npass_rand_range()/,/^}/p' "$PROJECT_DIR/lib/12-diceware.bash")
	local n=7776 limit
	limit=$((4294967296 - 4294967296 % n))
	[ "$limit" -lt 4294967296 ]   # existe bloco incompleto: o caso e real
	export QUEUE="$BATS_TEST_TMPDIR/q"
	od() { local v; v="$(head -n1 "$QUEUE")"; sed -i 1d "$QUEUE"; echo "   $v"; }
	# limite e limite+1 pertencem ao bloco incompleto: tem de ser descartados
	printf '%s\n' "$limit" "$((limit + 1))" 5 >"$QUEUE"
	[ "$(npass_rand_range "$n")" = "5" ]
	# o ultimo valor do ultimo bloco completo e aceito
	printf '%s\n' "$((limit - 1))" >"$QUEUE"
	[ "$(npass_rand_range "$n")" = "$(( (limit - 1) % n ))" ]
}

# --- o arquivo de listas -----------------------------------------------------------------------------

@test "wordlist.txt do repositorio: 3 secoes completas, alturas contiguas, sem palavra repetida" {
	local f="$PROJECT_DIR/encrypts_alternatives/wordlist.txt" sec exp dice
	for sec in large:5:7776 short1:4:1296 short2:4:1296; do
		IFS=: read -r name dice exp <<<"$sec"
		run awk -F'\t' -v s="[$name]" '/^\[/{c=$0; next} c==s && /^[1-6]+\t/ {print $1}' "$f"
		[ "$(wc -l <<<"$output")" -eq "$exp" ]
		# alturas = todas as combinacoes de dados, em ordem, sem buraco nem repeticao
		local want
		case "$dice" in
		5) want="$(printf '%s\n' {1..6}{1..6}{1..6}{1..6}{1..6})" ;;
		4) want="$(printf '%s\n' {1..6}{1..6}{1..6}{1..6})" ;;
		esac
		[ "$output" = "$want" ]
		run awk -F'\t' -v s="[$name]" '/^\[/{c=$0; next} c==s && /^[1-6]+\t/ {print $2}' "$f"
		[ "$(sort <<<"$output" | uniq -d | wc -l)" -eq 0 ]
	done
}

@test "wordlist.txt do repositorio: traz a atribuicao e a licenca da EFF" {
	run head -30 "$PROJECT_DIR/encrypts_alternatives/wordlist.txt"
	[[ "$output" == *"Electronic Frontier Foundation"* ]]
	[[ "$output" == *"Creative Commons Attribution 3.0"* ]]
}

# --- instalacao ---------------------------------------------------------------------------------------------

@test "install.sh instala a lista em share/npass/encrypts_alternatives e o binario instalado a encontra" {
	local prefix="$BATS_TEST_TMPDIR/prefix"
	run "$PROJECT_DIR/install.sh" --prefix="$prefix" --no-extensions
	[ "$status" -eq 0 ]
	local inst="$prefix/share/npass/encrypts_alternatives/wordlist.txt"
	cmp "$PROJECT_DIR/encrypts_alternatives/wordlist.txt" "$inst"
	[ "$(stat -c %a "$inst")" = "644" ]
	# usuario novo: a lista vem do share relativo ao binario instalado, para a arvore dele
	export NPASS_STORE="$BATS_TEST_TMPDIR/novo"
	"$prefix/bin/npass" init HG "$FPR" >/dev/null
	run "$prefix/bin/npass" diceware HG a/b
	[ "$status" -eq 0 ]
	[[ "$output" == *"a partir de $(readlink -f "$inst")"* ]]
	[[ "$output" != *"/../"* ]]
	cmp "$inst" "$NPASS_STORE/wordlist.txt"
}

@test "--uninstall remove a lista instalada e nao deixa diretorio vazio para tras" {
	local stage="$BATS_TEST_TMPDIR/stage"
	DESTDIR="$stage" "$PROJECT_DIR/install.sh" --prefix=/usr >/dev/null
	[ -f "$stage/usr/share/npass/encrypts_alternatives/wordlist.txt" ]
	DESTDIR="$stage" "$PROJECT_DIR/install.sh" --prefix=/usr --uninstall >/dev/null
	[ ! -e "$stage/usr/share/npass" ]
}
