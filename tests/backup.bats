#!/usr/bin/env bats
# npass backup: senhas de backup num arquivo cifrado anexo a uma entrada, e a
# cascata desse anexo em rm / mv / update / audit.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$PROJECT_DIR/bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	"$NPASS" init HG "$FPR" >/dev/null
	printf 'S3nhaPrincipal!\nS3nhaPrincipal!\n' | "$NPASS" insert HG email/gmail >/dev/null
}

# bk N [args...]: roda `npass backup -n N` alimentando as senhas c1..cN (cada uma 2x)
bk() {
	local n="$1" i input=""
	shift
	for ((i = 1; i <= n; i++)); do input+="c$i"$'\n'"c$i"$'\n'; done
	printf '%s' "$input" | "$NPASS" backup -n "$n" "$@"
}

count_blobs() { find "$NPASS_STORE/HG/blobs" -name '*.gpg' | wc -l; }

# --- uso e validacao ----------------------------------------------------------------------

@test "sem ID/caminho mostra uso; -n ausente ou fora de 1..50 e recusado; nada e gravado" {
	run "$NPASS" backup
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
	run "$NPASS" backup HG email/gmail
	[ "$status" -ne 0 ]
	[[ "$output" == *"quantidade inválida"* ]]
	for n in 0 51 abc 5.5 -1; do
		run "$NPASS" backup -n "$n" HG email/gmail
		[ "$status" -ne 0 ]
		[[ "$output" == *"quantidade inválida"* ]]
	done
	run "$NPASS" backup -n
	[ "$status" -ne 0 ]
	[ "$(count_blobs)" -eq 1 ]
}

@test "a entrada precisa existir: erro claro e nada gravado" {
	run bk 2 HG email/naoexiste
	[ "$status" -ne 0 ]
	[[ "$output" == *"não existe"* ]]
	[ "$(count_blobs)" -eq 1 ]
}

@test "identidade inexistente e caminho com .. sao recusados" {
	run bk 1 NAOEXISTE a/b
	[ "$status" -ne 0 ]
	run bk 1 HG ../fuga
	[ "$status" -ne 0 ]
	[ "$(count_blobs)" -eq 1 ]
}

@test "NPASS_LANG=en traduz o erro de quantidade" {
	NPASS_LANG=en run "$NPASS" backup -n 99 HG email/gmail
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid amount"* ]]
}

# --- fluxo feliz --------------------------------------------------------------------------

@test "grava ponteiro e arquivo de dados; a entrada principal fica intacta" {
	run bk 3 HG email/gmail
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 senhas de backup salvas em email/gmail/Backup-gmail.dados.md"* ]]
	[ "$(count_blobs)" -eq 3 ]
	[ "$("$NPASS" get HG email/gmail)" = "S3nhaPrincipal!" ]

	run "$NPASS" show HG email/gmail/Backup-gmail.md
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "<!-- npass:backup-index v1 -->" ]
	[[ "$output" == *"- arquivo: Backup-gmail.dados.md"* ]]
	[[ "$output" == *"- quantidade: 3"* ]]
	[[ "$output" =~ -\ criado:\ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]

	run "$NPASS" show HG email/gmail/Backup-gmail.dados.md
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "<!-- npass:backup-data v1 -->" ]
	[ "$output" = $'<!-- npass:backup-data v1 -->\n# Senhas de backup: gmail\n\n## Backup 1\nc1\n\n## Backup 2\nc2\n\n## Backup 3\nc3' ]

	run "$NPASS" ls --flat HG
	[[ "$output" == *"email/gmail/Backup-gmail.md"* ]]
	[[ "$output" == *"email/gmail/Backup-gmail.dados.md"* ]]
}

@test "o ponteiro nao carrega nenhuma senha de backup" {
	bk 2 HG email/gmail >/dev/null
	run "$NPASS" show HG email/gmail/Backup-gmail.md
	[[ "$output" != *"c1"* ]]
	[[ "$output" != *"c2"* ]]
}

@test "nada em claro no disco: as senhas de backup so existem cifradas" {
	printf 'ZZsegredoUnicoZZ\nZZsegredoUnicoZZ\n' | "$NPASS" backup -n 1 HG email/gmail >/dev/null
	run grep -rlF "ZZsegredoUnicoZZ" "$NPASS_STORE"
	[ "$status" -ne 0 ]
}

@test "senha com espacos nas pontas e caracteres de markdown e gravada exatamente" {
	printf '  # ## `x` *y*  \n  # ## `x` *y*  \n' | "$NPASS" backup -n 1 HG email/gmail >/dev/null
	run "$NPASS" show HG email/gmail/Backup-gmail.dados.md
	[ "${lines[3]}" = '  # ## `x` *y*  ' ]
}

@test "aceita -n com zero a esquerda e o caminho com subpasta" {
	printf 'x\nx\n' | "$NPASS" insert HG banco/conta/app >/dev/null
	run bk 2 HG banco/conta/app
	[ "$status" -eq 0 ]
	run "$NPASS" show HG banco/conta/app/Backup-app.dados.md
	[ "$status" -eq 0 ]
}

# --- entrada de senhas --------------------------------------------------------------------

@test "senha vazia, repetida ou com confirmacao diferente: falha e nada e gravado" {
	run bash -c "printf '\n\n' | '$NPASS' backup -n 1 HG email/gmail"
	[ "$status" -ne 0 ]
	[[ "$output" == *"vazia"* ]]
	run bash -c "printf 'a\na\na\na\n' | '$NPASS' backup -n 2 HG email/gmail"
	[ "$status" -ne 0 ]
	[[ "$output" == *"repete"* ]]
	run bash -c "printf 'a\nb\n' | '$NPASS' backup -n 1 HG email/gmail"
	[ "$status" -ne 0 ]
	[ "$(count_blobs)" -eq 1 ]
}

@test "EOF no meio da coleta: nada e gravado" {
	run bash -c "printf 'a\na\nb\n' | '$NPASS' backup -n 3 HG email/gmail"
	[ "$status" -ne 0 ]
	[ "$(count_blobs)" -eq 1 ]
}

# --- backup existente ---------------------------------------------------------------------

@test "backup existente: N cancela e mantem; y e -f substituem" {
	bk 2 HG email/gmail >/dev/null
	antes="$("$NPASS" show HG email/gmail/Backup-gmail.dados.md)"
	run bash -c "printf 'n\n' | '$NPASS' backup -n 1 HG email/gmail"
	[ "$status" -ne 0 ]
	[ "$("$NPASS" show HG email/gmail/Backup-gmail.dados.md)" = "$antes" ]

	run bash -c "printf 'y\nnovo\nnovo\n' | '$NPASS' backup -n 1 HG email/gmail"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG email/gmail/Backup-gmail.dados.md
	[[ "$output" == *"novo"* ]]
	[[ "$output" != *"c1"* ]]

	run bash -c "printf 'z1\nz1\nz2\nz2\n' | '$NPASS' backup -f -n 2 HG email/gmail"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG email/gmail/Backup-gmail.md
	[[ "$output" == *"- quantidade: 2"* ]]
	[ "$(count_blobs)" -eq 3 ]
}

@test "nome derivado ocupado por entrada do usuario (sem marcador): recusa e nao sobrescreve" {
	printf 'minha\nminha\n' | "$NPASS" insert HG email/gmail/Backup-gmail.md >/dev/null
	run bk 1 HG email/gmail
	[ "$status" -ne 0 ]
	[[ "$output" == *"não é um anexo de backup"* ]]
	[ "$("$NPASS" get HG email/gmail/Backup-gmail.md)" = "minha" ]
}

@test "backup sobre um anexo e recusado" {
	bk 1 HG email/gmail >/dev/null
	run bk 1 HG email/gmail/Backup-gmail.md
	[ "$status" -ne 0 ]
	[[ "$output" == *"anexo de backup"* ]]
}

# --- rm -----------------------------------------------------------------------------------

@test "rm da entrada leva os anexos junto e destroi os blobs" {
	bk 2 HG email/gmail >/dev/null
	[ "$(count_blobs)" -eq 3 ]
	run "$NPASS" rm -f HG email/gmail
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 anexo(s) de backup removido(s)"* ]]
	[ "$(count_blobs)" -eq 0 ]
	run "$NPASS" ls --flat HG
	[[ "$output" != *"Backup-"* ]]
}

@test "rm sem -f avisa dos anexos antes de perguntar; N cancela e mantem tudo" {
	bk 1 HG email/gmail >/dev/null
	run bash -c "printf 'n\n' | '$NPASS' rm HG email/gmail"
	[ "$status" -ne 0 ]
	[[ "$output" == *"2 anexo(s) de backup também serão removidos"* ]]
	[ "$(count_blobs)" -eq 3 ]
}

@test "rm de uma entrada sem backup nao muda de comportamento" {
	run "$NPASS" rm -f HG email/gmail
	[ "$status" -eq 0 ]
	[[ "$output" != *"anexo"* ]]
	[ "$(count_blobs)" -eq 0 ]
}

@test "rm nao arrasta entrada do usuario que so tem nome de anexo" {
	printf 'minha\nminha\n' | "$NPASS" insert HG email/gmail/Backup-x.md >/dev/null
	run "$NPASS" rm -f HG email/gmail
	[ "$status" -eq 0 ]
	[ "$("$NPASS" get HG email/gmail/Backup-x.md)" = "minha" ]
}

@test "rm de um anexo direto remove so ele" {
	bk 1 HG email/gmail >/dev/null
	run "$NPASS" rm -f HG email/gmail/Backup-gmail.dados.md
	[ "$status" -eq 0 ]
	[ "$("$NPASS" get HG email/gmail)" = "S3nhaPrincipal!" ]
	run "$NPASS" show HG email/gmail/Backup-gmail.md
	[ "$status" -eq 0 ]
	[ "$(count_blobs)" -eq 2 ]
}

# --- mv -----------------------------------------------------------------------------------

@test "mv na mesma identidade: anexos mudam de prefixo e continuam legiveis" {
	bk 2 HG email/gmail >/dev/null
	run "$NPASS" mv HG email/gmail email/google
	[ "$status" -eq 0 ]
	run "$NPASS" ls --flat HG
	[[ "$output" == *"email/google/Backup-gmail.md"* ]]
	[[ "$output" == *"email/google/Backup-gmail.dados.md"* ]]
	[[ "$output" != *"email/gmail"* ]]
	run "$NPASS" show HG email/google/Backup-gmail.dados.md
	[[ "$output" == *"c2"* ]]
}

@test "mv com destino que ja tem um anexo no caminho: falha e nao altera nada" {
	bk 1 HG email/gmail >/dev/null
	printf 'minha\nminha\n' | "$NPASS" insert HG email/novo/Backup-gmail.md >/dev/null
	antes="$("$NPASS" ls --flat HG)"
	run "$NPASS" mv HG email/gmail email/novo
	[ "$status" -ne 0 ]
	[[ "$output" == *"destino já tem anexo de backup"* ]]
	[ "$("$NPASS" ls --flat HG)" = "$antes" ]
	[ "$("$NPASS" get HG email/novo/Backup-gmail.md)" = "minha" ]
	[ "$("$NPASS" get HG email/gmail)" = "S3nhaPrincipal!" ]
}

@test "mv entre identidades recifra os anexos para o destino e limpa a origem" {
	"$NPASS" init HG2 "$FPR2" >/dev/null
	bk 2 HG email/gmail >/dev/null
	run "$NPASS" mv HG email/gmail HG2 conta/google
	[ "$status" -eq 0 ]
	run "$NPASS" get HG2 conta/google
	[ "$output" = "S3nhaPrincipal!" ]
	run "$NPASS" show HG2 conta/google/Backup-gmail.dados.md
	[ "$status" -eq 0 ]
	[[ "$output" == *"c1"* && "$output" == *"c2"* ]]
	run "$NPASS" show HG2 conta/google/Backup-gmail.md
	[ "$status" -eq 0 ]
	[ "$(count_blobs)" -eq 0 ]
}

# --- renomeacao + novo backup -------------------------------------------------------------

@test "depois de um mv que renomeia, um novo backup substitui o conjunto antigo (sem duplicar)" {
	bk 2 HG email/gmail >/dev/null
	"$NPASS" mv HG email/gmail email/google >/dev/null
	run bash -c "printf 'y\nn1\nn1\n' | '$NPASS' backup -n 1 HG email/google"
	[ "$status" -eq 0 ]
	run "$NPASS" ls --flat HG
	[[ "$output" == *"email/google/Backup-google.md"* ]]
	[[ "$output" == *"email/google/Backup-google.dados.md"* ]]
	[[ "$output" != *"Backup-gmail"* ]]
	[ "$(count_blobs)" -eq 3 ]
}

# --- update / audit -----------------------------------------------------------------------

@test "update por prefixo pula os anexos e nao os rotaciona" {
	bk 2 HG email/gmail >/dev/null
	antes="$("$NPASS" show HG email/gmail/Backup-gmail.dados.md)"
	run "$NPASS" update -f HG email/gmail/
	[ "$status" -eq 0 ]
	[ "$("$NPASS" show HG email/gmail/Backup-gmail.dados.md)" = "$antes" ]
	run "$NPASS" show HG email/gmail/Backup-gmail.md
	[ "${lines[0]}" = "<!-- npass:backup-index v1 -->" ]
}

@test "update ainda rotaciona a entrada principal normalmente" {
	bk 1 HG email/gmail >/dev/null
	run "$NPASS" update -f HG email/gmail
	[ "$status" -eq 0 ]
	[ "$("$NPASS" get HG email/gmail)" != "S3nhaPrincipal!" ]
	run "$NPASS" show HG email/gmail/Backup-gmail.dados.md
	[[ "$output" == *"c1"* ]]
}

@test "audit nao conta os anexos de backup como senhas" {
	command -v python3 >/dev/null || skip "python3 ausente"
	bk 2 HG email/gmail >/dev/null
	NPASS_BIN="$NPASS" run python3 "$PROJECT_DIR/extensions/npass-audit" HG --offline
	[ "$status" -eq 0 ]
	[[ "$output" == *"Resumo: 1 senha(s)"* ]]
}
