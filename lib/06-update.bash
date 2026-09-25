#!/usr/bin/env bash
# npass - update: bulk password rotation, ported from pass-update onto
# identity resolution. Usage: npass update [opts] ID PATTERN...
# A PATTERN is either an exact logical path or a prefix ending in "/"
# (expanded against the identity's map to every entry under it).
# There is no filesystem glob support here (the map isn't a filesystem
# tree), by design - see the M1 discussion of why the map is a flat,
# encrypted, atomically-written index rather than a directory layout.

cmd_update_usage() {
	cat <<-_EOF
		Uso: npass update [opts] ID PATTERN...

		  -c, --clip         copia a senha antiga para a área de transferência
		  -n, --no-symbols   gera sem símbolos
		  -l, --length N     comprimento da senha gerada
		  -a, --auto-length  usa o comprimento da senha antiga
		  -p, --provide      digita a nova senha manualmente
		  -m, --multiline    substitui o conteúdo inteiro (Ctrl+D para terminar)
		  -i, --include RE   só atualiza entradas cuja senha antiga casa RE
		  -e, --exclude RE   pula entradas cuja senha antiga casa RE
		  -E, --edit         abre cada entrada no \$EDITOR, ignora as opções acima
		  -f, --force        não pede confirmação

		PATTERN é um caminho lógico exato ou um prefixo terminado em "/".
	_EOF
}

npass_update_expand_patterns() {
	local dir="$1"; shift
	local -a out=()
	local pat physical
	for pat in "$@"; do
		if physical="$(npass_map_resolve "$dir" "$pat" 2>/dev/null)" && [[ -n "$physical" ]]; then
			out+=("$pat")
		elif [[ "$pat" == */ || -n "$(npass_map_list_prefix "$dir" "$pat")" ]]; then
			while IFS= read -r l; do
				[[ -n "$l" ]] && out+=("$l")
			done < <(npass_map_list_prefix "$dir" "$pat")
		else
			npass_warn "$pat não encontrado, ignorando."
		fi
	done
	printf '%s\n' "${out[@]}" | sort -u
}

cmd_update() {
	local clip=0 no_symbols=0 length="" autolength=0 provided=0 multiline=0
	local include="" exclude="" edit=0 force=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		-c | --clip) clip=1; shift ;;
		-n | --no-symbols) no_symbols=1; shift ;;
		-l | --length) length="$2"; shift 2 ;;
		-a | --auto-length) autolength=1; shift ;;
		-p | --provide) provided=1; shift ;;
		-m | --multiline) multiline=1; shift ;;
		-i | --include) include="$2"; shift 2 ;;
		-e | --exclude) exclude="$2"; shift 2 ;;
		-E | --edit) edit=1; shift ;;
		-f | --force) force=1; shift ;;
		-h | --help) cmd_update_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "opção desconhecida: $1" ;;
		esac
	done
	[[ $provided -eq 1 && $multiline -eq 1 ]] && npass_die "--provide e --multiline são mutuamente exclusivos"

	local id="$1"; shift
	[[ -z "$id" || $# -eq 0 ]] && { cmd_update_usage; npass_die "informe ID e ao menos um PATTERN"; }
	local dir; dir="$(npass_identity_dir "$id")"

	local -a targets=()
	while IFS= read -r l; do
		[[ -n "$l" ]] && targets+=("$l")
	done < <(npass_update_expand_patterns "$dir" "$@")
	[[ ${#targets[@]} -eq 0 ]] && npass_die "nenhuma entrada correspondente em $id"

	local logical content oldpw
	for logical in "${targets[@]}"; do
		if [[ $edit -eq 1 ]]; then
			cmd_edit "$id" "$logical"
			continue
		fi

		content="$(cmd_show "$id" "$logical")" || { npass_warn "$logical: falha ao decifrar, pulando"; continue; }
		oldpw="$(head -n1 <<<"$content")"

		[[ -n "$include" && ! "$oldpw" =~ $include ]] && continue
		[[ -n "$exclude" && "$oldpw" =~ $exclude ]] && continue

		printf '\033[1mAtualizando %s: %s\033[0m\n' "$id" "$logical"
		if [[ $clip -eq 0 ]]; then
			printf '%s\n' "$content"
		else
			npass_clip "$oldpw" "$id: $logical (senha antiga)"
		fi

		if [[ $force -eq 0 ]]; then
			local verb="gerar"
			[[ $provided -eq 1 || $multiline -eq 1 ]] && verb="fornecer"
			read -r -p "Pronto para $verb uma nova senha? [y/N] " reply
			[[ "$reply" == [yY] ]] || continue
		fi

		if [[ $provided -eq 1 ]]; then
			local newpw newpw2
			read -r -s -p "Nova senha para $id: $logical: " newpw || exit 1
			echo
			read -r -s -p "Repita: " newpw2 || exit 1
			echo
			[[ "$newpw" == "$newpw2" ]] || npass_die "as senhas não coincidem"
			npass_blob_write "$dir" "$logical" "$(npass_replace_first_line "$content" "$newpw")"
		elif [[ $multiline -eq 1 ]]; then
			echo "Digite o novo conteúdo de $logical e pressione Ctrl+D quando terminar:"
			local newcontent; newcontent="$(cat)"
			npass_blob_write "$dir" "$logical" "$newcontent"
		else
			local len="${length:-$NPASS_GENERATED_LENGTH}"
			[[ $autolength -eq 1 ]] && { len="${#oldpw}"; echo "Usando o comprimento da senha antiga: $len"; }
			local -a genopts=(--in-place --force)
			[[ $no_symbols -eq 1 ]] && genopts+=(--no-symbols)
			[[ $clip -eq 1 ]] && genopts+=(--clip)
			cmd_generate "${genopts[@]}" "$id" "$logical" "$len"
		fi
	done
}
