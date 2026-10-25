#!/usr/bin/env bats
# npass help: menu principal so com o essencial; o resto em categorias com secoes
# (lib/18-help.bash). Os testes protegem duas coisas: o menu enxuto, e que NENHUM
# comando (nem extensao) fique sem ajuda por ter saido do menu principal.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

CATS="entradas gerar otp backup buscar identidades git extensoes"

# fn CHAMADA...: roda uma funcao interna do npass
fn() { NPASS_SRC="$NPASS" "$BASH" -c 'source <(sed "\$d" "$NPASS_SRC"); "$@"' _ "$@"; }

# --- menu principal ---------------------------------------------------------------------------

@test "principal: versao, uso, o essencial e a lista de categorias" {
	run "$NPASS" help
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "npass "*" - Wayland-native password store"* ]]
	[[ "$output" == *"Uso: npass COMANDO ID DIR/PASS"* ]]
	[[ "$output" == *"Essencial:"* ]]
	local c
	for c in init ls show clip insert generate edit rm mv otp; do
		[[ "$output" == *$'\n'"  $c "* ]]
	done
	for c in $CATS; do
		[[ "$output" == *$'\n'"  $c "* ]]
	done
	[[ "$output" == *"npass help todos"* ]]
	[[ "$output" == *"npass help CATEGORIA SECAO"* ]]
}

@test "principal e enxuto: poucas linhas e nada de comando avancado" {
	run "$NPASS" help
	[ "${#lines[@]}" -le 40 ]
	local adv
	for adv in diceware memorable loglong "insert --batch" "extension sign" "pin (--password" "otp uri" "otp validate" "update [opts]" "grep ID"; do
		[[ "$output" != *"$adv"* ]]
	done
}

@test "sem argumentos, help, -h e --help sao a mesma coisa" {
	run "$NPASS"
	local base="$output"
	[ "$status" -eq 0 ]
	for a in help -h --help; do
		run "$NPASS" "$a"
		[ "$status" -eq 0 ]
		[ "$output" = "$base" ]
	done
}

@test "texto puro: nenhum escape de terminal" {
	run "$NPASS" help todos
	[[ "$output" != *$'\033'* ]]
}

@test "o essencial nao diz nada que o resto da ajuda desminta: cada comando essencial esta em help todos" {
	run "$NPASS" help
	local ess="$output"
	run "$NPASS" help todos
	local todos="$output" c
	for c in init ls show clip insert generate edit rm mv otp; do
		[[ "$todos" == *$'\n'"  $c "* ]]
	done
}

# --- categorias e secoes ---------------------------------------------------------------------------

@test "cada categoria listada no menu tem pagina, com cabecalho, secoes e o rodape de secao" {
	local c
	for c in $CATS; do
		run "$NPASS" help "$c"
		[ "$status" -eq 0 ]
		[[ "${lines[0]}" == "npass help $c - "* ]]
		[[ "$output" == *"Uma seção só: npass help $c SECAO"* ]]
		local sec
		for sec in $(fn npass_help_slugs "$c"); do
			[[ "$output" == *"($(fn npass_help_slugs "$c" | paste -sd' '))"* ]]
		done
	done
}

@test "as paginas mostram os titulos das secoes; os slugs sao ASCII sem acento" {
	run "$NPASS" help gerar
	[[ "$output" == *$'\nSenha aleatória\n'* ]]
	[[ "$output" == *$'\nFrases\n'* ]]
	[[ "$output" == *$'\nPIN numérico\n'* ]]
	run fn npass_help_slugs gerar
	[ "$output" = $'aleatoria\nfrases\npin' ]
}

@test "help CATEGORIA SECAO mostra so aquela secao" {
	run "$NPASS" help gerar frases
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "npass help gerar frases - Gerar senhas, frases e PINs" ]
	[[ "$output" == *"diceware"* ]]
	[[ "$output" == *"memorable"* ]]
	[[ "$output" != *"generate "* ]]
	[[ "$output" != *"pin ("* ]]
	[[ "$output" != *"Uma seção só"* ]]
}

@test "cada secao de cada categoria e alcancavel sozinha e nao vem vazia" {
	local c s
	for c in $CATS; do
		for s in $(fn npass_help_slugs "$c"); do
			run "$NPASS" help "$c" "$s"
			[ "$status" -eq 0 ]
			[[ "$output" == *$'\n  '* ]]   # tem ao menos uma linha de comando (indentada)
		done
	done
}

@test "categoria ou secao desconhecida: erro que lista as validas" {
	run "$NPASS" help xyz
	[ "$status" -eq 1 ]
	[[ "$output" == *"categoria de ajuda desconhecida: 'xyz'"* ]]
	[[ "$output" == *"entradas gerar otp backup buscar identidades git extensoes"* ]]
	run "$NPASS" help gerar xyz
	[ "$status" -eq 1 ]
	[[ "$output" == *"seção 'xyz' não existe em 'gerar' (seções: aleatoria frases pin)"* ]]
	NPASS_LANG=en run "$NPASS" help xyz
	[[ "$output" == *"unknown help category: 'xyz'"* ]]
}

@test "slug e exato: prefixo ou caixa diferente nao casam" {
	run "$NPASS" help Gerar
	[ "$status" -eq 1 ]
	run "$NPASS" help ger
	[ "$status" -eq 1 ]
	run "$NPASS" help gerar fra
	[ "$status" -eq 1 ]
}

# --- help todos: nada pode ficar sem ajuda ---------------------------------------------------------------

@test "help todos tem todas as categorias, na ordem do menu, e aliases all/tudo" {
	run "$NPASS" help todos
	[ "$status" -eq 0 ]
	local prev=0 c pos
	for c in $CATS; do
		pos="$(grep -n "^npass help $c - " <<<"$output" | cut -d: -f1)"
		[ -n "$pos" ]
		[ "$pos" -gt "$prev" ]
		prev="$pos"
	done
	local base="$output"
	run "$NPASS" help all
	[ "$output" = "$base" ]
	run "$NPASS" help tudo
	[ "$output" = "$base" ]
}

@test "todo comando despachado em 00-main.bash aparece em help todos (guarda contra comando sem ajuda)" {
	run "$NPASS" help todos
	local todos="$output" cmd n=0
	while IFS= read -r cmd; do
		case "$cmd" in tree | migrate | "''") continue ;; esac   # tree/migrate: aviso do comando antigo; '': o proprio help
		[[ "$todos" == *$'\n'"  $cmd "* || "$todos" == *$'\n'"  $cmd"$'\n'* ]] || { echo "sem ajuda: $cmd" >&3; false; }
		n=$((n + 1))
	done < <(awk '/^\t[a-z\x27][^)]*\)/ { sub(/^\t/, ""); sub(/\).*/, ""); split($0, a, / *\| */); print a[1] }' "$PROJECT_DIR/lib/00-main.bash")
	[ "$n" -ge 20 ]
}

@test "comandos antigos (tree, migrate) e o alias list nao aparecem como comando na ajuda" {
	run "$NPASS" help todos
	[[ "$output" != *$'\n'"  tree "* ]]
	[[ "$output" != *$'\n'"  list "* ]]
	[[ "$output" != *$'\n'"  migrate"* ]]
}

@test "toda extensao do repositorio esta listada em 'extensoes disponiveis'" {
	run "$NPASS" help extensoes disponiveis
	[ "$status" -eq 0 ]
	local out="$output" f name n=0
	for f in "$PROJECT_DIR"/extensions/npass-*; do
		[ -f "$f" ] || continue
		name="$(basename "$f")"; name="${name#npass-}"; name="${name%.bash}"
		[[ "$out" == *$'\n'"  $name "* ]] || { echo "extensao sem ajuda: $name" >&3; false; }
		n=$((n + 1))
	done
	[ "$n" -ge 5 ]
}

# --- integridade dos dados ---------------------------------------------------------------------------------

@test "slugs unicos: categorias entre si e secoes dentro de cada categoria" {
	run bash -c "source <(sed '\$d' '$NPASS'); npass_help_slugs | sort | uniq -d"
	[ -z "$output" ]
	local c
	for c in $CATS; do
		run bash -c "source <(sed '\$d' '$NPASS'); npass_help_slugs '$c' | sort | uniq -d"
		[ -z "$output" ]
	done
}

@test "formato dos dados: toda linha de conteudo e indentada; marcadores tem slug|texto" {
	run fn npass_help_data
	local l bad=0
	while IFS= read -r l; do
		[[ -z "$l" ]] && continue
		if [[ "$l" == @cat\ * || "$l" == @sub\ * ]]; then
			[[ "$l" == *"|"* ]] || bad=$((bad + 1))
		else
			[[ "$l" == "  "* ]] || bad=$((bad + 1))
		fi
	done <<<"$output"
	[ "$bad" -eq 0 ]
}
