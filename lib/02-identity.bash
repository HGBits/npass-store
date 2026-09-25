#!/usr/bin/env bash
# npass - identity resolution and the logical->physical secret map (v2).
#
# An "identity" is a directory under $NPASS_STORE containing .gpg-id.
# Its map (.map.gpg) is an encrypted TSV binding arbitrary logical paths
# ("email/gmail", "aws/root") to opaque physical filenames under
# blobs/. Renaming or moving a secret WITHIN an identity only edits the
# map — the ciphertext blob and its mtime never change. Moving BETWEEN
# identities is the one case that must decrypt+recrypt, because the
# recipient set changes.
#
# Every operation on the command line looks like: npass CMD ID DIR/PASS
# There is no classic "bare path" mode. ID is mandatory.

readonly NPASS_MAP_MAGIC="NPASS-MAP-1"

npass_identity_dir() {
	local id="$1"
	npass_check_sneaky_path "$id"
	local dir="$NPASS_STORE/$id"
	[[ -d "$dir" ]] || npass_die "identidade não encontrada: $id"
	[[ -f "$dir/.gpg-id" ]] || npass_die "'$id' não é uma identidade (sem .gpg-id)"
	printf '%s\n' "$dir"
}

npass_identity_init() {
	local id="$1" ; shift
	local -a recipients=("$@")
	npass_check_sneaky_path "$id"
	[[ ${#recipients[@]} -eq 0 ]] && npass_die "informe ao menos um destinatário GPG"
	local dir="$NPASS_STORE/$id"
	[[ -e "$dir/.gpg-id" ]] && npass_die "identidade já existe: $id"
	mkdir -p -- "$dir/blobs" || npass_die "falha ao criar identidade: $id"
	printf '%s\n' "${recipients[@]}" >"$dir/.gpg-id"
	NPASS_RECIPIENTS=("${recipients[@]}")
	npass_map_save "$dir" ""
	npass_git_commit "$id" "init"
	printf 'Identidade "%s" criada para: %s\n' "$id" "${recipients[*]}"
}

# --- map: load / save -----------------------------------------------------

# Decrypted map body on stdout, WITHOUT the magic header line.
# Empty (no .map.gpg yet) is valid and yields nothing.
npass_map_load() {
	local dir="$1" body
	local map="$dir/.map.gpg"
	[[ -f "$map" ]] || return 0
	body="$(npass_gpg_decrypt "$map")" || return 1
	local magic="${body%%$'\n'*}"
	if [[ "$magic" != "$NPASS_MAP_MAGIC" ]]; then
		npass_die "mapa corrompido ou de versão desconhecida em $dir"
	fi
	printf '%s\n' "${body#*$'\n'}"
}

# npass_map_save <id_dir> <body-without-header>
# Atomic: temp file + rename, serialized with flock so two concurrent
# `pass insert` on the same identity can't race and drop each other's
# entry (the original pass-secrets extension re-encrypted the whole
# mapfile with no locking at all).
npass_map_save() {
	local dir="$1" body="$2"
	local lock="$dir/.map.lock"
	npass_read_gpg_id "$dir"
	(
		exec {fd}>"$lock" || npass_die "falha ao abrir lock: $lock"
		flock -x "$fd" || npass_die "falha ao obter lock: $lock"
		local tmp
		tmp="$(npass_mktemp map)"
		{
			printf '%s\n' "$NPASS_MAP_MAGIC"
			[[ -n "$body" ]] && printf '%s\n' "$body"
		} >"$tmp"
		npass_gpg_encrypt NPASS_RECIPIENTS "$dir/.map.gpg" <"$tmp"
	)
}

# --- map: queries ----------------------------------------------------------

# Physical blob filename (without .gpg) for a logical path, or empty.
npass_map_resolve() {
	local dir="$1" logical="$2" body
	body="$(npass_map_load "$dir")" || return 1
	while IFS=$'\t' read -r l p; do
		[[ "$l" == "$logical" ]] && { printf '%s\n' "$p"; return 0; }
	done <<<"$body"
	return 1
}

# All logical paths in an identity, one per line, sorted.
npass_map_list() {
	local dir="$1" body
	body="$(npass_map_load "$dir")" || return 1
	[[ -z "$body" ]] && return 0
	cut -f1 <<<"$body" | sort
}

npass_map_list_prefix() {
	local dir="$1" prefix="$2"
	if [[ -n "$prefix" ]]; then
		npass_map_list "$dir" | grep -F -- "${prefix%/}/"
		return 0
	fi
	npass_map_list "$dir"
}

npass_new_blob_name() {
	head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# --- map: mutations ----------------------------------------------------------

npass_map_set() {
	local dir="$1" logical="$2" physical="$3"
	local lock="$dir/.map.lock"
	npass_check_sneaky_path "$logical"
	exec {fd}>"$lock" || npass_die "falha ao obter lock: $lock"
	flock -x "$fd"
	local body new_body="" found=0 l p
	body="$(npass_map_load "$dir")"
	while IFS=$'\t' read -r l p; do
		[[ -z "$l" ]] && continue
		if [[ "$l" == "$logical" ]]; then
			p="$physical"
			found=1
		fi
		new_body+="$l"$'\t'"$p"$'\n'
	done <<<"$body"
	[[ $found -eq 0 ]] && new_body+="$logical"$'\t'"$physical"$'\n'
	npass_read_gpg_id "$dir"
	local tmp
	tmp="$(npass_mktemp map)"
	{ printf '%s\n' "$NPASS_MAP_MAGIC"; printf '%s' "$new_body"; } >"$tmp"
	npass_gpg_encrypt NPASS_RECIPIENTS "$dir/.map.gpg" <"$tmp"
	exec {fd}>&-
}

npass_map_delete() {
	local dir="$1" logical="$2"
	local lock="$dir/.map.lock"
	exec {fd}>"$lock" || npass_die "falha ao obter lock: $lock"
	flock -x "$fd"
	local body new_body="" l p removed_physical=""
	body="$(npass_map_load "$dir")"
	while IFS=$'\t' read -r l p; do
		[[ -z "$l" ]] && continue
		if [[ "$l" == "$logical" ]]; then
			removed_physical="$p"
			continue
		fi
		new_body+="$l"$'\t'"$p"$'\n'
	done <<<"$body"
	npass_read_gpg_id "$dir"
	local tmp
	tmp="$(npass_mktemp map)"
	{ printf '%s\n' "$NPASS_MAP_MAGIC"; printf '%s' "$new_body"; } >"$tmp"
	npass_gpg_encrypt NPASS_RECIPIENTS "$dir/.map.gpg" <"$tmp"
	exec {fd}>&-
	printf '%s\n' "$removed_physical"
}

# Rename within the SAME identity: map-only edit, ciphertext untouched.
npass_map_rename() {
	local dir="$1" old="$2" new="$3"
	local lock="$dir/.map.lock"
	npass_check_sneaky_path "$new"
	exec {fd}>"$lock" || npass_die "falha ao obter lock: $lock"
	flock -x "$fd"
	local body new_body="" l p found=0
	body="$(npass_map_load "$dir")"
	while IFS=$'\t' read -r l p; do
		[[ -z "$l" ]] && continue
		if [[ "$l" == "$new" ]]; then
			npass_die "já existe uma entrada em '$new'"
		fi
		if [[ "$l" == "$old" ]]; then
			l="$new"
			found=1
		fi
		new_body+="$l"$'\t'"$p"$'\n'
	done <<<"$body"
	[[ $found -eq 0 ]] && npass_die "'$old' não encontrado"
	npass_read_gpg_id "$dir"
	local tmp
	tmp="$(npass_mktemp map)"
	{ printf '%s\n' "$NPASS_MAP_MAGIC"; printf '%s' "$new_body"; } >"$tmp"
	npass_gpg_encrypt NPASS_RECIPIENTS "$dir/.map.gpg" <"$tmp"
	exec {fd}>&-
}
