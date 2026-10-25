#!/usr/bin/env bats
# npass ls: arvore dos caminhos logicos. So le o mapa.
# --flat e a interface de maquina usada por npass-import e npass-audit.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	"$NPASS" init HG "$FPR" >/dev/null
}

# mk CAMINHO...: cria entradas
mk() {
	local p
	for p in "$@"; do printf 'x\nx\n' | "$NPASS" insert HG "$p" >/dev/null; done
}

# --- arvore ---------------------------------------------------------------------------

@test "arvore em UTF-8: ramos, pastas com / e entradas sem" {
	mk email/gmail email/outlook banco/itau/conta banco/itau/cartao banco/nubank solo
	LANG=C.UTF-8 LC_ALL=C.UTF-8 run "$NPASS" ls HG
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat <<'EOF'
HG
├── banco/
│   ├── itau/
│   │   ├── cartao
│   │   └── conta
│   └── nubank
├── email/
│   ├── gmail
│   └── outlook
└── solo
EOF
)" ]
}

@test "sem UTF-8 cai para ASCII" {
	mk a/b a/c
	LC_ALL=C LANG=C run "$NPASS" ls HG
	[ "$output" = $'HG\n`-- a/\n    |-- b\n    `-- c' ]
}

@test "so as pastas ganham / no fim; nome com espaco e preservado" {
	mk "a b/c d" solo
	LC_ALL=C.UTF-8 run "$NPASS" ls HG
	[[ "$output" == *"a b/"* ]]
	[[ "$output" == *"c d"* ]]
	[[ "$output" != *"solo/"* ]]
}

@test "entrada que tambem e pasta aparece sem / e com os filhos" {
	mk email/gmail email/gmail/extra
	LC_ALL=C.UTF-8 run "$NPASS" ls HG
	[[ "$output" == *$'├── gmail\n'* || "$output" == *$'└── gmail\n'* ]]
	[[ "$output" == *"extra"* ]]
	[[ "$output" != *"gmail/"* ]]
}

@test "ordem de arvore: o pai vem logo antes dos filhos, mesmo com irmao parecido (email.velho)" {
	mk email/gmail email.velho email/outlook
	run "$NPASS" ls --flat HG
	[ "$output" = $'email/gmail\nemail/outlook\nemail.velho' ]
}

# --- DIR: prefixo de verdade --------------------------------------------------------------------

@test "ls ID DIR mostra so o que esta sob DIR; DIR e a raiz do desenho" {
	mk banco/itau/conta banco/nubank email/gmail
	LC_ALL=C.UTF-8 run "$NPASS" ls HG banco
	[ "$output" = $'HG/banco\n├── itau/\n│   └── conta\n└── nubank' ]
}

@test "DIR com barra final funciona; prefixo e por componente (ban nao casa banco)" {
	mk banco/a bancos/b
	run "$NPASS" ls --flat HG banco/
	[ "$output" = "banco/a" ]
	run "$NPASS" ls --flat HG ban
	[ -z "$output" ]
}

@test "DIR que e uma entrada com filhos: a raiz e a entrada" {
	mk email/gmail email/gmail/x
	LC_ALL=C.UTF-8 run "$NPASS" ls HG email/gmail
	[ "$output" = $'HG/email/gmail\n└── x' ]
}

# --- [backup] -----------------------------------------------------------------------------------

@test "[backup] marca a entrada que tem o par de anexos, sem esconder os anexos" {
	mk email/gmail email/outlook
	printf 'b\nb\n' | "$NPASS" backup -n 1 HG email/gmail >/dev/null
	LC_ALL=C.UTF-8 run "$NPASS" ls HG
	[[ "$output" == *"gmail  [backup]"* ]]
	[[ "$output" != *"outlook  [backup]"* ]]
	[[ "$output" == *"Backup-gmail.dados.md"* ]]
	[[ "$output" == *"Backup-gmail.md"* ]]
}

@test "so o ponteiro sem o arquivo de dados (ou nome parecido) nao marca [backup]" {
	mk email/gmail email/gmail/Backup-x.md
	run "$NPASS" ls HG
	[[ "$output" != *"[backup]"* ]]
	# dados sem o ponteiro do mesmo nome (stems diferentes) tambem nao marca
	mk email/outlook email/outlook/Backup-a.dados.md email/outlook/Backup-b.md
	run "$NPASS" ls HG
	[[ "$output" != *"[backup]"* ]]
}

@test "[backup] tambem aparece na raiz quando DIR e a entrada" {
	mk email/gmail
	printf 'b\nb\n' | "$NPASS" backup -n 1 HG email/gmail >/dev/null
	run "$NPASS" ls HG email/gmail
	[ "${lines[0]}" = "HG/email/gmail  [backup]" ]
}

# --- cor -----------------------------------------------------------------------------------------

@test "fora de terminal nao ha codigo de escape (cor so com TTY)" {
	mk a/b
	run "$NPASS" ls HG
	[[ "$output" != *$'\033'* ]]
}

# --- --flat: a interface de maquina ----------------------------------------------------------------

@test "--flat: um caminho por linha, sem cabecalho, sem indentacao, sem enfeite" {
	mk email/gmail banco/nubank solo
	run "$NPASS" ls --flat HG
	[ "$status" -eq 0 ]
	[ "$output" = $'banco/nubank\nemail/gmail\nsolo' ]
}

@test "--flat de identidade vazia: saida vazia e status 0; ls mostra (vazio)" {
	run "$NPASS" ls --flat HG
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run "$NPASS" ls HG
	[ "$output" = "HG: (vazio)" ]
}

@test "--flat com DIR e a mesma filtragem da arvore" {
	mk banco/a banco/b email/c
	run "$NPASS" ls --flat HG banco
	[ "$output" = $'banco/a\nbanco/b' ]
}

# --- erros e o antigo tree ---------------------------------------------------------------------------

@test "identidade inexistente: erro e status != 0 (nao mais um '(vazio)' silencioso)" {
	run "$NPASS" ls NAOEXISTE
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade não encontrada"* ]]
	run "$NPASS" ls --flat NAOEXISTE
	[ "$status" -ne 0 ]
}

@test "sem ID mostra uso; opcao desconhecida e recusada; --help funciona" {
	run "$NPASS" ls
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso: npass ls"* ]]
	run "$NPASS" ls --nada HG
	[ "$status" -ne 0 ]
	run "$NPASS" ls --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--flat"* ]]
}

@test "o comando antigo tree falha e aponta para o ls; list e ls sao o mesmo comando" {
	run "$NPASS" tree HG
	[ "$status" -ne 0 ]
	[[ "$output" == *"npass ls"* ]]
	NPASS_LANG=en run "$NPASS" tree HG
	[ "$status" -ne 0 ]
	[[ "$output" == *"is now 'ls'"* ]]
	[ "$("$NPASS" list --flat HG)" = "$("$NPASS" ls --flat HG)" ]
}

@test "help lista o ls e nao lista mais o tree" {
	run "$NPASS" help todos
	[[ "$output" == *"ls [--flat] ID [DIR]"* ]]
	[[ "$output" != *"tree [--flat] ID [DIR]"* ]]
}
