#!/usr/bin/env bash
# npass tree [--flat] ID [DIR] - arvore dos caminhos logicos de uma identidade.
# Substitui o antigo `npass ls`.
#
#   npass tree pessoal            arvore (├── └──), com [backup] nas entradas que tem
#   npass tree pessoal email      so o que esta sob email/ (prefixo de verdade, por componente)
#   npass tree --flat pessoal     UM caminho logico por linha, sem enfeite: e a interface
#                                 de maquina (npass-import e npass-audit usam esta)
#
# So le o mapa: nao decifra nada. O mapa e plano (logico -> blob), entao a
# arvore sai de quebrar cada caminho em "/": um caminho e "entrada" se esta no
# mapa e "pasta" se so aparece como prefixo de outros. Uma entrada que tambem
# tem filhos (email/gmail e email/gmail/Backup-gmail.md) e as duas coisas.
#
# Nada e escondido. `[backup]` marca uma entrada que tem o par de anexos de
# `npass backup` (Backup-X.md e Backup-X.dados.md) sem decifrar: a marca vem
# so dos nomes, e os anexos continuam listados como filhos.

cmd_tree_usage() {
	printf '%s\n' "uso: npass tree [--flat] ID [DIR]" \
		"  arvore dos caminhos logicos de ID (opcionalmente so o que esta sob DIR)" \
		"  --flat   um caminho logico por linha, sem enfeite (para scripts)"
}

# npass_tree_paths DIR PREFIXO -> caminhos logicos sob PREFIXO (ou todos), na
# ordem de arvore: "/" vira \001 so para ordenar, de modo que um pai vem
# imediatamente antes dos seus filhos e antes de irmaos como "a.b" ou "a-b".
npass_tree_paths() {
	local dir="$1" prefix="$2"
	npass_map_list "$dir" \
		| LC_ALL=C awk -v p="$prefix" 'p == "" || $0 == p || index($0, p "/") == 1' \
		| LC_ALL=C sed $'s#/#\001#g' | LC_ALL=C sort | LC_ALL=C sed $'s#\001#/#g'
}

# npass_tree_render ID PREFIXO < caminhos (ja em ordem de arvore)
npass_tree_render() {
	local id="$1" prefix="$2" utf=0 color=0
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*[uU][tT][fF]-8* | *[uU][tT][fF]8*) utf=1 ;;
	esac
	[[ -t 1 && -z "${NO_COLOR:-}" ]] && color=1
	LC_ALL=C awk -v id="$id" -v prefix="$prefix" -v utf="$utf" -v color="$color" -v esc=$'\033' '
	BEGIN {
		if (utf) { T = "├── "; L = "└── "; V = "│   " } else { T = "|-- "; L = "`-- "; V = "|   " }
		S = "    "
		base = (prefix == "") ? 0 : split(prefix, tmp, "/")
	}
	{ paths[NR] = $0; isentry[$0] = 1 }
	END {
		# marca [backup]: existe pai/Backup-X.md E pai/Backup-X.dados.md
		for (i = 1; i <= NR; i++) {
			p = paths[i]
			if (p ~ /\/Backup-[^\/]+\.dados\.md$/) {
				k = split(p, c, "/")
				parent = ""
				for (d = 1; d < k; d++) parent = (d == 1) ? c[1] : parent "/" c[d]
				stem = substr(c[k], 1, length(c[k]) - length(".dados.md"))
				if ((parent "/" stem ".md") in isentry) hasbk[parent] = 1
			}
		}
		# nos: cada prefixo de cada caminho (abaixo do prefixo pedido) vira um no
		n = 0
		for (i = 1; i <= NR; i++) {
			k = split(paths[i], c, "/")
			acc = ""
			for (d = 1; d <= k; d++) {
				acc = (d == 1) ? c[1] : acc "/" c[d]
				if (d <= base) continue
				if (!(acc in seen)) { seen[acc] = 1; n++; name[n] = c[d]; depth[n] = d - base; full[n] = acc }
			}
		}
		root = (prefix == "") ? id : id "/" prefix
		tag = ((prefix in hasbk) ? "  [backup]" : "")
		if (color && tag != "") tag = esc "[2m" tag esc "[0m"
		print root tag
		for (i = 1; i <= n; i++) {
			last = 1
			for (j = i + 1; j <= n; j++) {
				if (depth[j] <= depth[i]) { last = (depth[j] < depth[i]); break }
			}
			lastAt[depth[i]] = last
			pre = ""
			for (d = 1; d < depth[i]; d++) pre = pre (lastAt[d] ? S : V)
			nm = name[i]
			if (!(full[i] in isentry)) {
				nm = nm "/"
				if (color) nm = esc "[1;34m" nm esc "[0m"
			}
			if (full[i] in hasbk) nm = nm (color ? esc "[2m  [backup]" esc "[0m" : "  [backup]")
			print pre (last ? L : T) nm
		}
	}'
}

cmd_tree() {
	local flat=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		--flat) flat=1; shift ;;
		-h | --help) cmd_tree_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" prefix="${2%/}"
	[[ -z "$id" ]] && npass_die "uso: npass tree [--flat] ID [DIR]"
	local dir
	dir="$(npass_identity_dir "$id")" || exit 1
	local list
	list="$(npass_tree_paths "$dir" "$prefix")"
	if ((flat)); then
		[[ -n "$list" ]] && printf '%s\n' "$list"
		return 0
	fi
	if [[ -z "$list" ]]; then
		printf '%s: (vazio)\n' "$id"
		return 0
	fi
	npass_tree_render "$id" "$prefix" <<<"$list"
}
