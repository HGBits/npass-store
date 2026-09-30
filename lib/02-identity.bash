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
	[[ -d "$dir" ]] || npass_die "$(npass_t erro_id_nao_encontrada "$id")"
	[[ -f "$dir/.gpg-id" ]] || npass_die "$(npass_t erro_id_sem_gpgid "$id")"
	printf '%s\n' "$dir"
}

npass_identity_init() {
	local sign=0 sign_keyid=""
	while [[ "$1" == --sign* ]]; do
		case "$1" in
		--sign) sign=1; shift ;;
		--sign=*) sign=1; sign_keyid="${1#--sign=}"; shift ;;
		esac
	done
	local id="$1" ; shift
	local -a recipients=("$@")
	npass_check_sneaky_path "$id"
	[[ ${#recipients[@]} -eq 0 ]] && npass_die "$(npass_t erro_informe_destinatario)"
	local dir="$NPASS_STORE/$id"
	[[ -e "$dir/.gpg-id" ]] && npass_die "$(npass_t erro_id_ja_existe "$id")"
	mkdir -p -- "$dir/blobs" || npass_die "$(npass_t erro_falha_criar_id "$id")"
	npass_git_ensure || npass_warn "$(npass_t warn_sem_git)"
	printf '%s\n' "${recipients[@]}" >"$dir/.gpg-id"
	NPASS_RECIPIENTS=("${recipients[@]}")
	npass_map_save "$dir" ""
	[[ $sign -eq 1 ]] && npass_sign_gpgid "$dir" "$sign_keyid"
	npass_git_commit "$id" "init"
	npass_t msg_id_criada "$id" "${recipients[*]}"
}

# --- map: load / save -----------------------------------------------------

# Decrypted map body on stdout, WITHOUT the magic header line.
# Empty (no .map.gpg yet) is valid and yields nothing.
npass_map_load() {
	local dir="$1" body
	npass_tomb_require_open "$dir"
	local map="$dir/.map.gpg"
	[[ -f "$map" ]] || return 0
	body="$(npass_gpg_decrypt "$map")" || return 1
	local magic="${body%%$'\n'*}"
	if [[ "$magic" != "$NPASS_MAP_MAGIC" ]]; then
		npass_die "$(npass_t erro_mapa_corrompido "$dir")"
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
		exec {fd}>"$lock" || npass_die "$(npass_t erro_lock_abrir "$lock")"
		flock -x "$fd" || npass_die "$(npass_t erro_lock_obter "$lock")"
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

# --- readable blob names -----------------------------------------------------
#
# Physical blob names are pronounceable pseudonyms ("Bavodu.gpg",
# "Kelitum.gpg"), not hex. They are drawn from /dev/urandom and carry NO
# information about the entry: never derived from the logical path, so
# they leak nothing a random hex name would not. The point is that a
# human looking at the directory (or `git log --stat`) can tell the files
# apart and see they are blobs, without decrypting anything.

NPASS_SYL_C=(b c d f g h j k l m n p r s t v w x y z)
NPASS_SYL_V=(a e i o u)
NPASS_RPOOL=()
NPASS_RPOS=0

# Unbiased random integer in [0, n), n <= 256, returned in $REPLY
# (not on stdout: the byte pool must survive between calls, and a
# command substitution would throw that state away). Rejection sampling
# avoids the modulo bias of a plain `byte % n`.
npass_rand_below() {
	local n="$1" b lim=$((256 - 256 % $1))
	while :; do
		if ((NPASS_RPOS >= ${#NPASS_RPOOL[@]})); then
			read -r -d '' -a NPASS_RPOOL < <(head -c 64 /dev/urandom | od -An -v -tu1) || true
			NPASS_RPOS=0
		fi
		b="${NPASS_RPOOL[NPASS_RPOS]}"
		((NPASS_RPOS++))
		if ((b < lim)); then
			REPLY=$((b % n))
			return 0
		fi
	done
}

# npass_blob_name_taken DIR NAME - case-insensitive, because the store
# is meant to travel to case-insensitive filesystems ("Azaus" and
# "azaus" must never coexist).
npass_blob_name_taken() {
	local dir="$1" want="${2,,}" f
	for f in "$dir/blobs"/*.gpg; do
		[[ -e "$f" ]] || continue
		f="${f##*/}"
		f="${f,,}"
		[[ "${f%.gpg}" == "$want" ]] && return 0
	done
	return 1
}

# npass_new_blob_name [ID_DIR] - fresh unique name on stdout.
# Starts at 3 syllables (~20 bits) and grows a syllable every few
# collisions, so a very large identity degrades to longer names instead
# of looping.
npass_new_blob_name() {
	local dir="$1" syl=3 tries=0 name i
	while :; do
		name=""
		for ((i = 0; i < syl; i++)); do
			npass_rand_below "${#NPASS_SYL_C[@]}"
			name+="${NPASS_SYL_C[REPLY]}"
			npass_rand_below "${#NPASS_SYL_V[@]}"
			name+="${NPASS_SYL_V[REPLY]}"
		done
		npass_rand_below 2
		if ((REPLY == 1)); then
			npass_rand_below "${#NPASS_SYL_C[@]}"
			name+="${NPASS_SYL_C[REPLY]}"
		fi
		name="${name^}"
		if [[ -z "$dir" ]] || ! npass_blob_name_taken "$dir" "$name"; then
			printf '%s\n' "$name"
			return 0
		fi
		((++tries % 6 == 0)) && ((syl++))
	done
}

# --- map: mutations ----------------------------------------------------------

npass_map_set() {
	local dir="$1" logical="$2" physical="$3"
	local lock="$dir/.map.lock"
	npass_check_sneaky_path "$logical"
	exec {fd}>"$lock" || npass_die "$(npass_t erro_lock_obter "$lock")"
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
	exec {fd}>"$lock" || npass_die "$(npass_t erro_lock_obter "$lock")"
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
	exec {fd}>"$lock" || npass_die "$(npass_t erro_lock_obter "$lock")"
	flock -x "$fd"
	local body new_body="" l p found=0
	body="$(npass_map_load "$dir")"
	while IFS=$'\t' read -r l p; do
		[[ -z "$l" ]] && continue
		if [[ "$l" == "$new" ]]; then
			npass_die "$(npass_t erro_entrada_existe "$new")"
		fi
		if [[ "$l" == "$old" ]]; then
			l="$new"
			found=1
		fi
		new_body+="$l"$'\t'"$p"$'\n'
	done <<<"$body"
	[[ $found -eq 0 ]] && npass_die "$(npass_t erro_nao_encontrado "$old")"
	npass_read_gpg_id "$dir"
	local tmp
	tmp="$(npass_mktemp map)"
	{ printf '%s\n' "$NPASS_MAP_MAGIC"; printf '%s' "$new_body"; } >"$tmp"
	npass_gpg_encrypt NPASS_RECIPIENTS "$dir/.map.gpg" <"$tmp"
	exec {fd}>&-
}

# --- identities: list ----------------------------------------------------------

# npass identities - one line per identity: "NAME - N senhas".
# N is the number of blob files on disk. Deliberately NOT read from the
# encrypted map: counting through the map would decrypt every identity
# and trigger one pinentry prompt each, just to print a listing.
cmd_identities() {
	case "$1" in
	-h | --help)
		printf '%s\n' "uso: npass identities"
		return 0
		;;
	'') ;;
	*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
	esac
	local d id n found=0
	for d in "$NPASS_STORE"/*/; do
		[[ -f "${d}.gpg-id" ]] || continue
		id="${d%/}"
		id="${id##*/}"
		n="$(find "${d}blobs" -maxdepth 1 -type f -name '*.gpg' 2>/dev/null | wc -l)"
		n=$((n))
		found=1
		if ((n == 1)); then
			npass_t msg_id_linha_um "$id"
		else
			npass_t msg_id_linha "$id" "$n"
		fi
	done
	[[ $found -eq 1 ]] || npass_t msg_sem_identidades "$NPASS_STORE"
}
