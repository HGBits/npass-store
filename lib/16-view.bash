#!/usr/bin/env bash
# npass show - ver uma entrada, renderizada com glow quando e para humanos.
#
#   npass show ID DIR/PASS           em terminal: markdown renderizado pelo glow;
#                                    em pipe/script/extensao: o documento CRU (md1)
#   npass show --raw ID DIR/PASS     sempre cru
#   npass show --render ID DIR/PASS  sempre renderizado (mesmo em pipe: p/ `less -R`)
#   NPASS_SHOW_RENDER=auto|always|never   padrao de quem nao quer passar a flag
#
# O que o glow recebe NAO e o documento md1, e sim um documento so de EXIBICAO.
# Markdown renderizado deforma texto: `a*b*c_d_` viraria italico, `<`, `&` e `\`
# somem, uma senha que comeca com `#` viraria titulo. Voce copiaria da tela uma
# senha diferente da guardada. Entao senha, valores de campo e OTP vao em bloco
# ou span de codigo (a cerca e sempre mais longa que qualquer sequencia de crases
# do proprio texto, e os nomes sao escapados). So as notas sao markdown de verdade.
#
# NAVEGACAO CONTEXTUAL (calculada, nunca gravada). Ao renderizar, o documento de
# exibicao ganha links npass:// que o npass descobre olhando o mapa:
#   entrada principal   ->  "Backup: [Asyx](npass://ID/QWAP/Asyx/Backup-Asyx.dados.md)"
#   anexo de backup     ->  "Entrada: [Asyx](npass://ID/QWAP/Asyx)"  (e o ponteiro liga ao arquivo de dados)
# Nada disso vai para o conteudo cifrado: `show --raw`, `get`, `clip` e as extensoes
# nao veem os links, e um mv/rm/rename nunca deixa um link velho para tras. Um par de
# anexos so conta se existirem os DOIS nomes (Backup-X.md e Backup-X.dados.md); a
# decisao e so por nome, sem decifrar. Clicar num link chama `npass open` (17-open).
#
# O texto vai ao glow por stdin, nunca por argumento (nada de senha em
# /proc/*/cmdline) e nada e gravado em disco. Para COPIAR use `npass clip`: o
# glow desenha margem e preenchimento ao redor do texto, e selecionar da tela
# leva isso junto.
#
# cmd_show (03-store) continua sendo o decifrador cru que os outros comandos
# usam por dentro; so o COMANDO `npass show` passa por aqui.

# npass_md_escape TEXTO -> texto com escape de markdown (barra invertida antes
# da pontuacao que o markdown interpreta).
npass_md_escape() {
	printf '%s' "$1" | LC_ALL=C sed -E 's/([][\\`*_{}()<>#+!|~&])/\\\1/g'
}

# npass_md_ticks TEXTO -> uma sequencia de crases maior que qualquer uma no texto
# (minimo 1 para span, 3 para bloco: o chamador passa o minimo em $2).
npass_md_ticks() {
	local rest="$1" min="$2" max=0 re='(`+)' fence
	while [[ "$rest" =~ $re ]]; do
		((${#BASH_REMATCH[1]} > max)) && max=${#BASH_REMATCH[1]}
		rest="${rest#*"${BASH_REMATCH[0]}"}"
	done
	((max + 1 < min)) && max=$((min - 1))
	printf -v fence '%*s' "$((max + 1))" ''
	printf '%s' "${fence// /\`}"
}

# npass_md_fence TEXTO -> bloco de codigo cercado, o texto exatamente como esta.
npass_md_fence() {
	local fence
	fence="$(npass_md_ticks "$1" 3)"
	printf '%s\n%s\n%s\n' "$fence" "$1" "$fence"
}

# npass_md_code TEXTO -> span de codigo. Os espacos de cada lado sao removidos pelo
# markdown (uma vez, nos dois lados), entao o texto sai exato mesmo comecando ou
# terminando com crase ou espaco.
npass_md_code() {
	local t
	t="$(npass_md_ticks "$1" 1)"
	printf '%s %s %s' "$t" "$1" "$t"
}

# npass_display_value VALOR -> um valor de campo: autolink se for URL web, senao codigo.
# A regex exclui espaco, < > ( ) crase e barra invertida, entao o autolink nunca fecha antes da hora.
npass_display_value() {
	local v="$1" re='^https?://[^[:space:]<>()`\\]+$'
	if [[ -z "$v" ]]; then
		printf '*(vazio)*'
	elif [[ "$v" =~ $re ]]; then
		printf '<%s>' "$v"   # autolink: o glow mostra a URL uma vez so (link com texto repetia)
	else
		npass_md_code "$v"
	fi
}

# npass_nav_url ID LOGICAL -> npass://ID/caminho%20codificado
npass_nav_url() {
	printf 'npass://%s/%s' "$1" "$(npass_url_encode "$2")"
}

# npass_nav_backups DIR LOGICAL -> "stem<TAB>caminho-do-arquivo-de-dados" por par
# completo de anexos sob a entrada (so nomes, sem decifrar), ordenado por stem.
npass_nav_backups() {
	local dir="$1" logical="$2" l rest stem
	local -A haveptr=()
	local -a datas=()
	while IFS= read -r l; do
		[[ "$l" == "$logical"/Backup-*.md ]] || continue
		rest="${l#"$logical"/}"
		[[ "$rest" == */* ]] && continue
		if [[ "$rest" == Backup-*.dados.md ]]; then
			datas+=("$rest")
		else
			haveptr["$rest"]=1
		fi
	done < <(npass_map_list "$dir")
	for rest in "${datas[@]}"; do
		stem="${rest#Backup-}"
		stem="${stem%.dados.md}"
		[[ -n "$stem" && -n "${haveptr["Backup-$stem.md"]:-}" ]] && printf '%s\t%s/%s\n' "$stem" "$logical" "$rest"
	done | LC_ALL=C sort
}

# npass_nav_line_backups ID DIR LOGICAL -> "Backup: [a](url), [b](url)" ou nada.
npass_nav_line_backups() {
	local id="$1" dir="$2" logical="$3" stem path out=""
	while IFS=$'\t' read -r stem path; do
		[[ -n "$stem" ]] || continue
		[[ -n "$out" ]] && out+=", "
		out+="[$(npass_md_escape "$stem")]($(npass_nav_url "$id" "$path"))"
	done < <(npass_nav_backups "$dir" "$logical")
	[[ -n "$out" ]] && printf 'Backup: %s' "$out"
	return 0
}

# npass_nav_line_parent ID DIR LOGICAL -> "Entrada: [nome](url)" do pai de um anexo.
npass_nav_line_parent() {
	local id="$1" dir="$2" logical="$3" parent
	[[ "$logical" == */* ]] || return 0
	parent="${logical%/*}"
	if [[ -n "$(npass_map_resolve "$dir" "$parent" 2>/dev/null)" ]]; then
		printf 'Entrada: [%s](%s)' "$(npass_md_escape "${parent##*/}")" "$(npass_nav_url "$id" "$parent")"
	else
		printf 'Entrada: *(não encontrada)*'
	fi
}

# npass_display_entry LOGICAL [NAV] -> documento de exibicao da entrada md1 ja carregada
# em NPASS_E_* (npass_entry_load/_require).
npass_display_entry() {
	local logical="$1" nav="${2-}" l re='^-[[:space:]]+([^:]+):[[:space:]]*(.*)$' k
	printf '# %s\n\n' "$(npass_md_escape "$logical")"
	[[ -n "$nav" ]] && printf '%s\n\n' "$nav"
	printf '## Senha\n\n'
	if [[ -n "$NPASS_E_PW" ]]; then
		npass_md_fence "$NPASS_E_PW"
	else
		printf '*(vazia)*\n'
	fi
	if ((${#NPASS_E_FIELDS[@]})); then
		printf '\n## Campos\n\n'
		for l in "${NPASS_E_FIELDS[@]}"; do
			if [[ "$l" =~ $re ]]; then
				k="${BASH_REMATCH[1]}"
				k="${k#"${k%%[![:space:]]*}"}"
				k="${k%"${k##*[![:space:]]}"}"
				printf -- '- **%s**: %s\n' "$(npass_md_escape "$k")" "$(npass_display_value "${BASH_REMATCH[2]}")"
			else
				printf -- '- %s\n' "$(npass_md_escape "$l")"
			fi
		done
	fi
	if ((${#NPASS_E_OTP[@]})); then
		printf '\n## OTP\n\n'
		npass_md_fence "$(printf '%s\n' "${NPASS_E_OTP[@]}")"
	fi
	if [[ -n "$NPASS_E_NOTES" ]]; then
		printf '\n## Notas\n\n%s\n' "$NPASS_E_NOTES"
	fi
}

# npass_display_backup LOGICAL CONTEUDO [NAV] [ID] -> exibicao de um anexo de
# `npass backup`. NAV e a linha "Entrada: ..."; ID liga o campo "arquivo" do ponteiro
# ao arquivo de dados (irmao dele, no mesmo diretorio logico).
npass_display_backup() {
	local logical="$1" content="$2" nav="${3-}" id="${4-}" line expect=0 re='^-[[:space:]]+([^:]+):[[:space:]]*(.*)$' k v
	printf '# %s\n\n' "$(npass_md_escape "$logical")"
	[[ -n "$nav" ]] && printf '%s\n\n' "$nav"
	if [[ "${content%%$'\n'*}" == '<!-- npass:backup-data v1 -->' ]]; then
		while IFS= read -r line; do
			if ((expect)); then
				npass_md_fence "$line"
				expect=0
			elif [[ "$line" =~ ^'## Backup '([0-9]+)$ ]]; then
				printf '\n## Backup %s\n\n' "${BASH_REMATCH[1]}"
				expect=1
			fi
		done <<<"$content"
	else
		while IFS= read -r line; do
			if [[ "$line" =~ $re ]]; then
				k="${BASH_REMATCH[1]}"
				v="${BASH_REMATCH[2]}"
				if [[ "$k" == arquivo && -n "$id" && "$logical" == */* && "$v" =~ ^Backup-[^/]+\.dados\.md$ ]]; then
					printf -- '- **%s**: [%s](%s)\n' "$(npass_md_escape "$k")" "$(npass_md_escape "$v")" "$(npass_nav_url "$id" "${logical%/*}/$v")"
				else
					printf -- '- **%s**: %s\n' "$(npass_md_escape "$k")" "$(npass_display_value "$v")"
				fi
			fi
		done <<<"$content"
	fi
}

# npass_glow_render < documento -> renderizado. 127 se nao ha glow.
npass_glow_render() {
	local bin="${NPASS_GLOW:-glow}"
	command -v "$bin" >/dev/null 2>&1 || return 127
	# sem -p o glow nao abre pager (testado no v3.0.0; `--pager=false` ao contrario ATIVA
	# o pager nessa versao). Se o glow.yml de quem usa tiver `pager: true`, a escolha e dele.
	local -a args=()
	[[ -n "${NPASS_GLOW_STYLE:-}" ]] && args+=(-s "$NPASS_GLOW_STYLE")
	[[ -n "${NPASS_GLOW_WIDTH:-}" ]] && args+=(-w "$NPASS_GLOW_WIDTH")
	"$bin" "${args[@]}" -
}

cmd_view() {
	local mode="${NPASS_SHOW_RENDER:-auto}"
	while [[ "$1" == -* ]]; do
		case "$1" in
		-r | --raw) mode=never; shift ;;
		--render) mode=always; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass show [--raw|--render] ID DIR/PASS"
	case "$mode" in
	always) ;;
	never) cmd_show "$id" "$logical"; return ;;
	*) [[ -t 1 ]] || { cmd_show "$id" "$logical"; return; } ;;
	esac

	local content
	content="$(cmd_show "$id" "$logical")" || exit 1
	local doc dir nav=""
	dir="$(npass_identity_dir "$id")" || exit 1
	if npass_entry_load "$content"; then
		nav="$(npass_nav_line_backups "$id" "$dir" "$logical")"
		doc="$(npass_display_entry "$logical" "$nav")"
	elif npass_backup_is_marker "$content"; then
		nav="$(npass_nav_line_parent "$id" "$dir" "$logical")"
		doc="$(npass_display_backup "$logical" "$content" "$nav" "$id")"
	else
		# fora de md1 ou estrutura invalida: nao ha o que renderizar com seguranca
		printf '%s\n' "$content"
		return 0
	fi
	local rendered rc
	rendered="$(printf '%s\n' "$doc" | npass_glow_render)"
	rc=$?
	if ((rc != 0)); then
		if ((rc == 127)); then
			npass_warn "$(npass_t warn_glow_ausente)"
		else
			npass_warn "$(npass_t warn_glow_falhou "$rc")"
		fi
		printf '%s\n' "$content"
		return 0
	fi
	printf '%s\n' "$rendered"
}
