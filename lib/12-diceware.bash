#!/usr/bin/env bash
# npass - diceware passphrases from the EFF wordlists.
#
#   npass diceware   Words from the EFF Large list (7776). The passphrase goes
#                    into the vault. The user is shown only the HEIGHT of each
#                    word - its dice number in the published list - to write on
#                    paper, so the passphrase can be rebuilt by hand if the
#                    password manager is ever lost. The words are not printed.
#   npass memorable  Words from the two EFF Short lists. Meant to be memorised,
#                    so there is NO height and nothing to write down.
#
# Heights are never stored by npass: not in the vault, the map, git, a log or a
# file. They exist on the terminal (stderr) only at the moment of generation.
#
# The wordlist is plain DATA, never executed, at $NPASS_STORE/wordlist.txt (or
# $NPASS_WORDLIST). On first use it is copied there from the copy that ships
# with npass (encrypts_alternatives/wordlist.txt in the repository). Format:
# comment lines, "[section]" lines, and "HEIGHT<TAB>word" lines.

readonly NPASS_PASSPHRASE_MIN_WORDS=4
readonly NPASS_PASSPHRASE_MAX_WORDS=20
readonly NPASS_PASSPHRASE_DEFAULT_WORDS=6
readonly NPASS_PASSPHRASE_DEFAULT_SEP="-"
# Smallest official list is 6^4 = 1296 words. A file with fewer usable words
# than that was truncated or tampered with - a tiny list would silently make
# every future passphrase weak - so refuse it instead of generating from it.
readonly NPASS_WORDLIST_MIN_POOL=1296

# --- wordlist: where it is, getting it into place, loading it -------------------

npass_wordlist_path() {
	printf '%s\n' "${NPASS_WORDLIST:-$NPASS_STORE/wordlist.txt}"
}

# Where the shipped copy can be read FROM. Explicit override first, then relative
# to this executable: an install (PREFIX/bin/npass -> PREFIX/share/npass/...) and
# a repository checkout (bin/npass -> encrypts_alternatives/...).
npass_wordlist_template() {
	if [[ -n "${NPASS_WORDLIST_SRC:-}" ]]; then
		printf '%s\n' "$NPASS_WORDLIST_SRC"
		return 0
	fi
	local self dir cand
	self="$(readlink -f -- "$0" 2>/dev/null)"
	dir="${self%/*}"
	for cand in "$dir/../share/npass/encrypts_alternatives/wordlist.txt" \
		"$dir/../encrypts_alternatives/wordlist.txt"; do
		if [[ -f "$cand" ]]; then
			readlink -f -- "$cand" # clean path for the message, not ".../bin/../share/..."
			return 0
		fi
	done
	return 1
}

# Prints the path of the user's wordlist, creating it from the shipped copy the
# first time. Never overwrites an existing file.
npass_wordlist_ensure() {
	local wl src
	wl="$(npass_wordlist_path)"
	if [[ ! -f "$wl" ]]; then
		src="$(npass_wordlist_template)" || npass_die "$(npass_t erro_wordlist_ausente "$wl")"
		[[ -f "$src" ]] || npass_die "$(npass_t erro_wordlist_ausente "$wl")"
		mkdir -p -- "${wl%/*}" && install -m 644 -- "$src" "$wl" \
			|| npass_die "$(npass_t erro_wordlist_copiar "$src" "$wl")"
		npass_warn "$(npass_t warn_wordlist_copiada "$wl" "$src")"
	fi
	printf '%s\n' "$wl"
}

# npass_wordlist_load FILE SECTION...
# Fills the parallel arrays NPASS_WL_H (heights) and NPASS_WL_W (words) with the
# well-formed rows of the named sections. A word repeated across the chosen
# sections is kept once (first wins), so every distinct word is equally likely.
# Malformed rows are skipped, not trusted.
npass_wordlist_load() {
	local file="$1"
	shift
	NPASS_WL_H=()
	NPASS_WL_W=()
	local h w
	while IFS=$'\t' read -r h w; do
		NPASS_WL_H+=("$h")
		NPASS_WL_W+=("$w")
	done < <(LC_ALL=C awk -F'\t' -v want=" $* " '
		/^[[:space:]]*(#|$)/ { next }
		/^[[:space:]]*@list[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*$/ {
			cur = $2
			next
		}
		cur != "" && index(want, " " cur " ") &&
		NF == 2 &&
		$1 ~ /^[1-6]+$/ &&
		$2 ~ /^[a-z-]+$/ &&
		!seen[$2]++ {
			print $1 "\t" $2
		}
	' "$file")
}

# --- randomness -----------------------------------------------------------------

# Uniform integer in [0, n) on stdout, for 1 <= n <= 2^32. Draws 32 random bits
# and REJECTS values from the incomplete last block, so there is no modulo bias.
npass_rand_range() {
	local n="$1" v limit
	limit=$((4294967296 - 4294967296 % n))
	while :; do
		v="$(od -An -N4 -tu4 -v /dev/urandom)"
		v="${v//[[:space:]]/}"
		[[ "$v" =~ ^[0-9]+$ ]] || npass_die "$(npass_t erro_entropia)"
		if ((v < limit)); then
			printf '%d\n' $((v % n))
			return 0
		fi
	done
}

# --- options --------------------------------------------------------------------

# Dies unless SEP is at most 3 characters with no control characters (a newline
# would break the one-line password; a tab, the map format). Characters are
# counted as UTF-8 code points regardless of locale: drop continuation bytes.
npass_passphrase_sep_check() {
	local sep="$1" origin="$2" chars
	chars="$(printf '%s' "$sep" | LC_ALL=C tr -d '\200-\277' | wc -c)"
	if ((chars > 3)) || [[ "$sep" == *[[:cntrl:]]* ]]; then
		npass_die "$(npass_t erro_separador_invalido "$origin")"
	fi
}

# --- the two commands -----------------------------------------------------------

# npass_passphrase_cmd MODE [opts] ID DIR/PASS [WORDS]      MODE: diceware | memorable
npass_passphrase_cmd() {
	local mode="$1"
	shift
	local force=0 inplace=0 clip=0 sep="" sep_from="" list_opt=""
	while [[ "${1:-}" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		--in-place) inplace=1; shift ;;
		-c | --clip) clip=1; shift ;;
		-s | --sep)
			[[ $# -ge 2 ]] || npass_die "$(npass_t erro_opcao_desconhecida "$1")"
			sep="$2"; sep_from="--sep"; shift 2 ;;
		--sep=*) sep="${1#--sep=}"; sep_from="--sep"; shift ;;
		-l | --list)
			[[ $# -ge 2 ]] || npass_die "$(npass_t erro_opcao_desconhecida "$1")"
			list_opt="$2"; shift 2 ;;
		--list=*) list_opt="${1#--list=}"; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="${1:-}" logical="${2:-}" count="${3:-$NPASS_PASSPHRASE_DEFAULT_WORDS}"
	[[ -z "$id" || -z "$logical" ]] \
		&& npass_die "uso: npass $mode [-c] [-f] [--in-place] [-s SEP]$([[ $mode == memorable ]] && printf ' [-l short|short1|short2]') ID DIR/PASS [PALAVRAS]"
	npass_check_sneaky_path "$logical"

	if [[ ! "$count" =~ ^[0-9]+$ ]] \
		|| ((count < NPASS_PASSPHRASE_MIN_WORDS || count > NPASS_PASSPHRASE_MAX_WORDS)); then
		npass_die "$(npass_t erro_palavras_invalido "$count" "$NPASS_PASSPHRASE_MIN_WORDS" "$NPASS_PASSPHRASE_MAX_WORDS")"
	fi

	# Separator: --sep wins, then the preset NPASS_DICEWARE_SEP (empty is allowed
	# and means "no separator"), then the default.
	if [[ -z "$sep_from" ]]; then
		if [[ -n "${NPASS_DICEWARE_SEP+x}" ]]; then
			sep="$NPASS_DICEWARE_SEP"; sep_from="NPASS_DICEWARE_SEP"
		else
			sep="$NPASS_PASSPHRASE_DEFAULT_SEP"; sep_from="padrão"
		fi
	fi
	npass_passphrase_sep_check "$sep" "$sep_from"

	# Fail on a bad wordlist BEFORE asking the user to confirm an overwrite.
	local wl sections
	wl="$(npass_wordlist_ensure)" || exit 1
	if [[ "$mode" == diceware ]]; then
		# Heights only make sense for ONE list: the 5-dice numbers of [large] are
		# unambiguous, while 4-dice numbers exist in both short lists.
		[[ -z "$list_opt" ]] || npass_die "$(npass_t erro_opcao_desconhecida "--list")"
		sections="large"
	else
		case "${list_opt:-short}" in
		short) sections="short1 short2" ;;
		short1 | short2) sections="$list_opt" ;;
		*) npass_die "$(npass_t erro_lista_invalida "$list_opt")" ;;
		esac
	fi
	# shellcheck disable=SC2086 # sections is a deliberate word list
	npass_wordlist_load "$wl" $sections
	local pool="${#NPASS_WL_W[@]}"
	((pool >= NPASS_WORDLIST_MIN_POOL)) \
		|| npass_die "$(npass_t erro_wordlist_pequena "$wl" "$pool" "$NPASS_WORDLIST_MIN_POOL")"

	local dir has_entry=0 existing="" reply
	dir="$(npass_identity_dir "$id")"
	npass_map_resolve "$dir" "$logical" >/dev/null 2>&1 && has_entry=1
	# Read the current content ONLY for --in-place, which keeps part of it. If the
	# entry exists but cannot be decrypted (cancelled pinentry, missing key, damaged
	# blob), stop: treating "unreadable" as "empty" would silently overwrite data we
	# never saw, and skip the confirmation below.
	if ((has_entry)) && [[ $inplace -eq 1 ]]; then
		existing="$(cmd_show "$id" "$logical")" \
			|| npass_die "$(npass_t erro_entrada_ilegivel "$id" "$logical")"
	fi
	if ((has_entry)) && [[ $inplace -eq 0 && $force -eq 0 ]]; then
		read -r -p "$(npass_t prompt_sobrescrever_existe "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi

	local phrase="" heights="" i idx
	for ((i = 0; i < count; i++)); do
		idx="$(npass_rand_range "$pool")"
		((i > 0)) && { phrase+="$sep"; heights+=" "; }
		phrase+="${NPASS_WL_W[idx]}"
		heights+="${NPASS_WL_H[idx]}"
	done

	local content="$phrase"
	if [[ $inplace -eq 1 && $has_entry -eq 1 ]]; then
		content="$(npass_replace_first_line "$existing" "$phrase")"
	fi
	npass_blob_write "$dir" "$logical" "$content"
	npass_git_commit "$id" "$mode"

	local bits sep_shown
	bits="$(awk -v n="$count" -v p="$pool" 'BEGIN { printf "%.1f", n * log(p) / log(2) }')"
	if [[ "$mode" == diceware ]]; then
		sep_shown="\"$sep\""
		[[ -z "$sep" ]] && sep_shown="$(npass_t rotulo_sem_separador)"
		# stderr on purpose: the heights are as sensitive as the password, so they
		# must not land in a pipe, a file or a $(...) by accident.
		{
			npass_t msg_diceware_cab "$count" "$id" "$logical" "$pool" "$bits"
			npass_t msg_diceware_alturas "$heights"
			npass_t msg_diceware_sep "$sep_shown"
			npass_t msg_diceware_recuperar "$wl"
			npass_t msg_diceware_aviso
		} >&2
		[[ $clip -eq 1 ]] && npass_clip "$phrase" "$id: $logical"
	else
		npass_t msg_memorable_info "$count" "$id" "$logical" "$pool" "$bits" >&2
		if [[ $clip -eq 1 ]]; then
			npass_clip "$phrase" "$id: $logical"
		else
			printf '%s\n' "$phrase"
		fi
	fi
	return 0
}

cmd_diceware() { npass_passphrase_cmd diceware "$@"; }
cmd_memorable() { npass_passphrase_cmd memorable "$@"; }
