#!/usr/bin/env bats
#
# Guarda contra dependencias alucinadas por IA ("slopsquatting").
#
# Nao ha lista publica canonica de "nomes mais comuns" alucinados (so casos
# isolados, como huggingface-cli); por isso a defesa principal e ESTRUTURAL:
# tudo que o projeto declara ou sonda precisa estar numa allowlist verificada
# por um humano (tests/deps/*.txt). Um nome novo quebra o teste ate alguem
# confirmar que ele existe. A denylist cobre apenas casos comprovados.
#
# Limites: so enxerga comandos sondados com `command -v`/`type -P` e nomes em
# manifests; uma chamada direta a um binario inexistente no meio do codigo nao e
# detectada aqui.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	DEPS="$BATS_TEST_DIRNAME/deps"
}

# primeiro token de cada linha util (ignora comentarios, vazias e "| motivo")
list_names() {
	grep -vE '^[[:space:]]*(#|$)' "$1" | sed -E 's/[[:space:]]*(#|\|).*$//; s/[[:space:]]+$//' | awk 'NF{print $1}'
}

# comandos sondados em codigo NAO comentado: `command -v NOME` / `type -P NOME`
probed_in() {
	local f
	for f in "$@"; do
		[[ -f $f ]] || continue
		grep -vE '^[[:space:]]*#' "$f" \
			| grep -oE '(command -v|type -P)[[:space:]]+[A-Za-z0-9_][A-Za-z0-9_.+-]*' \
			| awk '{print $NF}'
	done | sort -u
}

not_in_list() { # $1 = arquivo de allowlist; stdin = nomes; imprime os que faltam
	local n allowed
	allowed="$(list_names "$1")"
	while IFS= read -r n; do
		[[ -z $n ]] && continue
		grep -qxF -- "$n" <<<"$allowed" || printf '%s\n' "$n"
	done
}

@test "allowlists e denylist existem, sem duplicatas, e a denylist traz motivo" {
	local f dup
	for f in commands packages denylist; do
		[ -s "$DEPS/$f.txt" ]
		dup="$(list_names "$DEPS/$f.txt" | sort | uniq -d)"
		[ -z "$dup" ] || { echo "duplicado em $f.txt: $dup" >&2; false; }
	done
	# toda linha da denylist precisa de "| motivo"
	run bash -c "grep -vE '^[[:space:]]*(#|\$)' '$DEPS/denylist.txt' | grep -vE '\\|[[:space:]]*[^[:space:]]'"
	[ -z "$output" ]
}

@test "o parser de comandos le codigo real e ignora comentarios (o guarda nao pode apodrecer)" {
	cat >"$BATS_TEST_TMPDIR/amostra.bash" <<'AMOSTRA'
# command -v comentado_nao_conta
command -v realcmd >/dev/null || true
x="$(type -P outrocmd || true)"
command -v "$variavel" >/dev/null
AMOSTRA
	run probed_in "$BATS_TEST_TMPDIR/amostra.bash"
	[ "$status" -eq 0 ]
	[ "$output" = $'outrocmd\nrealcmd' ]
}

@test "todo comando sondado por command -v esta na allowlist (pega binarios inventados tipo otptool)" {
	local missing
	missing="$(probed_in "$ROOT"/lib/*.bash "$ROOT/install.sh" "$ROOT/release.sh" | not_in_list "$DEPS/commands.txt")"
	[ -z "$missing" ] || {
		printf 'comando fora da allowlist: %s\n' $missing >&2
		echo "Confirme que existe (pacman -Si/-F, registro) e adicione em tests/deps/commands.txt" >&2
		false
	}
}

@test "todo pacote do PKGBUILD (depends/makedepends/optdepends) esta na allowlist" {
	[ -f "$ROOT/packaging/PKGBUILD" ] || skip "sem PKGBUILD"
	local names missing
	names="$(bash -c 'source "$1"; printf "%s\n" "${depends[@]}" "${makedepends[@]}" "${optdepends[@]}"' _ "$ROOT/packaging/PKGBUILD" \
		| sed -E 's/:.*$//; s/[<>=].*$//' | sort -u)"
	[ -n "$names" ]
	missing="$(not_in_list "$DEPS/packages.txt" <<<"$names")"
	[ -z "$missing" ] || {
		printf 'pacote fora da allowlist: %s\n' $missing >&2
		false
	}
}

@test "em maquina Arch, todo pacote da allowlist existe nos repositorios (pacman -Si)" {
	command -v pacman >/dev/null || skip "pacman ausente (rode numa maquina Arch)"
	local p bad=()
	while IFS= read -r p; do
		pacman -Si "$p" >/dev/null 2>&1 || bad+=("$p")
	done < <(list_names "$DEPS/packages.txt")
	[ ${#bad[@]} -eq 0 ] || { printf 'nao encontrado em pacman -Si: %s\n' "${bad[@]}" >&2; false; }
}

@test "nenhum nome da denylist aparece no projeto (codigo, docs, manifests)" {
	local name hits all=""
	while IFS= read -r name; do
		hits="$(grep -rInwiF \
			--exclude-dir=.git --exclude-dir=bin --exclude-dir=gnupg_test --exclude-dir=gnupg_atacante \
			--exclude-dir=dist --exclude-dir=target --exclude-dir=deps \
			--exclude=deps.bats --exclude=otp.bats \
			-e "$name" -- "$ROOT" 2>/dev/null || true)"
		[ -z "$hits" ] || all+="[$name]"$'\n'"$hits"$'\n'
	done < <(list_names "$DEPS/denylist.txt")
	[ -z "$all" ] || { printf '%s' "$all" >&2; false; }
}

@test "workflows usam so acoes de owners confiaveis e nunca refs flutuantes (@main/@master)" {
	local f bad=""
	shopt -s nullglob
	for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
		bad+="$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$f" | grep -vE 'uses:[[:space:]]*actions/[A-Za-z0-9_.-]+@(v[0-9]+(\.[0-9]+){0,2}|[0-9a-f]{40})([[:space:]]|$)' || true)"
	done
	[ -z "$bad" ] || { printf 'uses fora da politica (actions/* @vN ou SHA):\n%s\n' "$bad" >&2; false; }
}
