#!/usr/bin/env bash
# npass - store commands operating through the identity map.
# Every command takes ID DIR/PASS. There is no bare-path mode.

npass_blob_path() {
	local dir="$1" physical="$2"
	printf '%s\n' "$dir/blobs/$physical.gpg"
}

# npass_blob_write ID_DIR LOGICAL CONTENT
# Writes CONTENT (full file body, may be multi-line) to the logical path,
# reusing its existing physical blob name if it already exists (so a
# content update never touches the map or the blob's identity - only the
# ciphertext bytes change). Creates a new blob+map entry otherwise.
npass_blob_write() {
	local dir="$1" logical="$2" content="$3"
	local existing; existing="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)"
	local physical="${existing:-$(npass_new_blob_name "$dir")}"
	npass_read_gpg_id "$dir"
	npass_gpg_encrypt NPASS_RECIPIENTS "$(npass_blob_path "$dir" "$physical")" <<<"$content"
	if [[ -z "$existing" ]]; then
		npass_map_set "$dir" "$logical" "$physical"
	fi
	return 0
}

cmd_show() {
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass show ID DIR/PASS"
	local dir physical
	dir="$(npass_identity_dir "$id")"
	physical="$(npass_map_resolve "$dir" "$logical")" || npass_die "$(npass_t erro_logico_nao_encontrado "$id" "$logical")"
	[[ -z "$physical" ]] && npass_die "$(npass_t erro_logico_nao_encontrado "$id" "$logical")"
	npass_gpg_decrypt "$(npass_blob_path "$dir" "$physical")"
}

# npass insert --batch [-f] ID
# Bulk write for tools (the import extension feeds this). Records arrive on
# stdin as   LOGICAL_PATH NUL CONTENT NUL   pairs: content may span many
# lines and never touches argv, the environment or the disk in plaintext.
# Existing entries are skipped unless -f. One signature check up front and
# ONE git commit at the end, instead of one commit per secret.
cmd_insert_batch() {
	local force="$1" id="$2"
	[[ -z "$id" ]] && npass_die "uso: npass insert --batch [-f] ID   (registros CAMINHO\\0CONTEUDO\\0 no stdin)"
	local dir; dir="$(npass_identity_dir "$id")"
	local logical content existing written=0 skipped=0
	while IFS= read -r -d '' logical && IFS= read -r -d '' content; do
		npass_check_sneaky_path "$logical"
		if [[ $force -eq 0 ]]; then
			existing="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)"
			if [[ -n "$existing" ]]; then
				((skipped++))
				continue
			fi
		fi
		npass_blob_write "$dir" "$logical" "$content"
		((written++))
	done
	npass_git_commit "$id" "insert-batch"
	npass_t msg_batch_resumo "$id" "$written" "$skipped"
}

cmd_insert() {
	local force=0 batch=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		--batch) batch=1; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	if [[ $batch -eq 1 ]]; then
		cmd_insert_batch "$force" "$@"
		return
	fi
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass insert [-f] ID DIR/PASS"
	local dir existing
	dir="$(npass_identity_dir "$id")"
	existing="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)"
	if [[ -n "$existing" && $force -eq 0 ]]; then
		read -r -p "$(npass_t prompt_sobrescrever "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi
	local secret secret2
	read -r -s -p "$(npass_t prompt_senha_para "$id" "$logical")" secret; echo
	read -r -s -p "$(npass_t prompt_repita_senha)" secret2; echo
	[[ "$secret" == "$secret2" ]] || npass_die "$(npass_t erro_senhas_diferentes)"

	npass_blob_write "$dir" "$logical" "$secret"
	npass_git_commit "$id" "insert"
	npass_t msg_salvo "$id" "$logical"
}

cmd_rm() {
	local force=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass rm [-f] ID DIR/PASS"
	local dir
	dir="$(npass_identity_dir "$id")"
	if [[ $force -eq 0 ]]; then
		read -r -p "$(npass_t prompt_remover "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi
	local physical
	physical="$(npass_map_delete "$dir" "$logical")"
	[[ -z "$physical" ]] && npass_die "$(npass_t erro_logico_nao_encontrado "$id" "$logical")"
	local blob
	blob="$(npass_blob_path "$dir" "$physical")"
	if [[ -f "$blob" ]]; then
		shred -u -- "$blob" 2>/dev/null || rm -f -- "$blob"
	fi
	npass_git_commit "$id" "rm"
	npass_t msg_removido "$id" "$logical"
}

# npass mv ID DIR/PASS ID2 DIR2/PASS2   -> cross-identity: decrypt+recrypt
# npass mv ID DIR/PASS DIR2/PASS2       -> same identity: map-only rename
cmd_mv() {
	local id="$1" from="$2" a="$3" b="$4"
	[[ -z "$id" || -z "$from" ]] && npass_die "uso: npass mv ID DIR/PASS [ID2] DIR2/PASS2"
	local dir; dir="$(npass_identity_dir "$id")"
	if [[ -n "$b" ]]; then
		# cross-identity move: id from -> a (dest id) b (dest logical)
		local dst_id="$a" dst_logical="$b"
		local dst_dir; dst_dir="$(npass_identity_dir "$dst_id")"
		local plaintext
		plaintext="$(cmd_show "$id" "$from")" || return 1
		local existing
		existing="$(npass_map_resolve "$dst_dir" "$dst_logical" 2>/dev/null)"
		[[ -n "$existing" ]] && npass_die "$(npass_t erro_dest_ja_existe "$dst_id" "$dst_logical")"
		npass_blob_write "$dst_dir" "$dst_logical" "$plaintext"
		local old_physical; old_physical="$(npass_map_delete "$dir" "$from")"
		local old_blob; old_blob="$(npass_blob_path "$dir" "$old_physical")"
		[[ -f "$old_blob" ]] && shred -u -- "$old_blob" 2>/dev/null
		npass_git_commit "$dst_id" "mv-in"
		npass_git_commit "$id" "mv-out"
		printf '%s: %s -> %s: %s\n' "$id" "$from" "$dst_id" "$dst_logical"
	else
		# same-identity rename: map-only, ciphertext untouched
		local to="$a"
		[[ -z "$to" ]] && npass_die "uso: npass mv ID DIR/PASS DIR2/PASS2"
		npass_map_rename "$dir" "$from" "$to"
		npass_git_commit "$id" "mv"
		printf '%s: %s -> %s\n' "$id" "$from" "$to"
	fi
}

# Replace only the first line of a multi-line blob, preserving the rest
# (an otpauth:// line, notes, etc.) untouched. Used by generate --in-place
# and by update's password rotation, so rotating a password never drops
# the OTP secret that lives alongside it.
npass_replace_first_line() {
	local content="$1" newline="$2" rest
	rest="$(tail -n +2 <<<"$content")"
	if [[ -n "$rest" ]]; then
		printf '%s\n%s' "$newline" "$rest"
	else
		printf '%s' "$newline"
	fi
}

: "${NPASS_GENERATED_LENGTH:=25}"

cmd_generate() {
	local no_symbols=0 clip=0 inplace=0 force=0 length=""
	while [[ "$1" == -* ]]; do
		case "$1" in
		-n | --no-symbols) no_symbols=1; shift ;;
		-c | --clip) clip=1; shift ;;
		-f | --force) force=1; shift ;;
		--in-place) inplace=1; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" logical="$2"
	[[ -n "$3" ]] && length="$3"
	length="${length:-$NPASS_GENERATED_LENGTH}"
	[[ "$length" =~ ^[0-9]+$ && "$length" -gt 0 ]] || npass_die "$(npass_t erro_comprimento_invalido "$length")"

	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass generate [-n] [-c] [-f] [--in-place] ID DIR/PASS [LENGTH]"
	local dir; dir="$(npass_identity_dir "$id")"
	local existing; existing="$(cmd_show "$id" "$logical" 2>/dev/null || true)"
	if [[ -n "$existing" && $inplace -eq 0 && $force -eq 0 ]]; then
		read -r -p "$(npass_t prompt_sobrescrever_existe "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi

	local charset='A-Za-z0-9'
	[[ $no_symbols -eq 0 ]] && charset+='!@#$%^&*()_+=-'
	local pw
	pw="$(LC_ALL=C tr -dc "$charset" </dev/urandom | head -c "$length")"
	[[ "${#pw}" -eq "$length" ]] || npass_die "$(npass_t erro_entropia)"

	local new_content
	if [[ $inplace -eq 1 && -n "$existing" ]]; then
		new_content="$(npass_replace_first_line "$existing" "$pw")"
	else
		new_content="$pw"
	fi
	npass_blob_write "$dir" "$logical" "$new_content"
	npass_git_commit "$id" "generate"

	if [[ $clip -eq 1 ]]; then
		npass_clip "$pw" "$id: $logical"
	else
		printf '%s\n' "$pw"
	fi
}

cmd_edit() {
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass edit ID DIR/PASS"
	local dir; dir="$(npass_identity_dir "$id")"
	local existing; existing="$(cmd_show "$id" "$logical" 2>/dev/null || true)"
	local tmp; tmp="$(npass_mktemp edit)"
	[[ -n "$existing" ]] && printf '%s' "$existing" >"$tmp"
	"${EDITOR:-vi}" "$tmp" || npass_die "$(npass_t erro_editor)"
	local new_content; new_content="$(cat "$tmp")"
	if [[ "$new_content" == "$existing" ]]; then
		npass_t msg_sem_alteracoes
		return 0
	fi
	npass_blob_write "$dir" "$logical" "$new_content"
	npass_git_commit "$id" "edit"
	npass_t msg_atualizado "$id" "$logical"
}

cmd_ls() {
	local id="$1" prefix="$2"
	[[ -z "$id" ]] && npass_die "uso: npass ls ID [DIR]"
	local dir; dir="$(npass_identity_dir "$id")"
	local entries; entries="$(npass_map_list_prefix "$dir" "$prefix")"
	if [[ -z "$entries" ]]; then
		printf '%s: (vazio)\n' "$id"
		return 0
	fi
	printf '%s\n' "$id"
	sed 's/^/  /' <<<"$entries"
}

cmd_find() {
	local id="$1" pattern="$2"
	[[ -z "$id" || -z "$pattern" ]] && npass_die "uso: npass find ID PADRÃO"
	local dir; dir="$(npass_identity_dir "$id")"
	local matches; matches="$(npass_map_list "$dir" | grep -i -- "$pattern")"
	if [[ -z "$matches" ]]; then
		return 1
	fi
	printf '%s\n' "$id"
	sed 's/^/  /' <<<"$matches"
}

# npass grep ID [GREP-OPTIONS] PADRÃO
# Decrypts every entry in the identity to search its content - this is
# inherently O(n) in the number of secrets, same as upstream pass grep;
# there's no way to grep ciphertext.
cmd_grep() {
	local id="$1"; shift
	[[ -z "$id" || $# -eq 0 ]] && npass_die "uso: npass grep ID [OPÇÕES-DO-GREP] PADRÃO"
	local -a grepopts=()
	while [[ $# -gt 1 ]]; do
		grepopts+=("$1"); shift
	done
	local pattern="$1"
	local dir; dir="$(npass_identity_dir "$id")"
	local logical content matches found=0
	while IFS= read -r logical; do
		[[ -z "$logical" ]] && continue
		content="$(cmd_show "$id" "$logical" 2>/dev/null)" || continue
		matches="$(printf '%s\n' "$content" | grep -n "${grepopts[@]}" -- "$pattern" 2>/dev/null)"
		if [[ -n "$matches" ]]; then
			found=1
			printf '%s: %s\n' "$id" "$logical"
			sed 's/^/  /' <<<"$matches"
		fi
	done < <(npass_map_list "$dir")
	[[ $found -eq 1 ]]
}
