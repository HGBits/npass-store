#!/usr/bin/env bash
# npass - PIN generation.
#
#   npass pin --password ID DIR/PASS [DIGITS]   the PIN IS the entry's password (line 1)
#   npass pin --field    ID DIR/PASS [DIGITS]   the PIN is an independent "pin: ..." field,
#                                               next to whatever password the entry has
#
# The two modes are separate on purpose and one MUST be chosen. Some systems take the
# PIN as THE password; others take it as an extra factor next to a password. Guessing
# a default would either overwrite a real password with a PIN, or leave a PIN where
# the system expects a password.
#
# --field reads back through `npass clip pin ID DIR/PASS` like any "key: value" field.
#
# Digits come from /dev/urandom filtered through tr, which keeps only the 10 digit
# bytes, so every digit is equally likely (no modulo bias) - the same technique
# `generate` uses. A PIN is a STRING: leading zeros are significant, so it never goes
# through arithmetic.

: "${NPASS_PIN_LENGTH:=6}"
readonly NPASS_PIN_MIN_DIGITS=4
readonly NPASS_PIN_MAX_DIGITS=32

# npass_pin_digits N -> N random digits on stdout, leading zeros preserved.
npass_pin_digits() {
	local n="$1" pin
	pin="$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c "$n")"
	[[ "${#pin}" -eq "$n" ]] || npass_die "$(npass_t erro_entropia)"
	printf '%s\n' "$pin"
}

# npass_pin_has_field CONTENT -> success if a line after the first is a "pin:" field.
# The key rule is the one `npass clip` uses: text before the first ":", trimmed,
# case-insensitive. Line 1 is the password and is never a field.
npass_pin_has_field() {
	local line key first=1 re='^([^:[:space:]][^:]*):'
	while IFS= read -r line; do
		if ((first)); then
			first=0
			continue
		fi
		if [[ "$line" =~ $re ]]; then
			key="${BASH_REMATCH[1]}"
			key="${key%"${key##*[![:space:]]}"}"
			[[ "${key,,}" == pin ]] && return 0
		fi
	done <<<"$1"
	return 1
}

# npass_pin_set_field CONTENT PIN -> new content on stdout. Replaces the FIRST "pin:"
# line (the one `npass clip pin` reads) or, if there is none, adds "pin: PIN" at the
# end of the field block - before the first blank line after line 1, which is where
# notes start - or at the very end. Every other line is left byte for byte as it was,
# line 1 (the password) included.
npass_pin_set_field() {
	local content="$1" pin="$2" line key i blank=-1 replaced=0 re='^([^:[:space:]][^:]*):'
	local -a lines=()
	while IFS= read -r line; do lines+=("$line"); done <<<"$content"
	for ((i = 1; i < ${#lines[@]}; i++)); do
		line="${lines[i]}"
		if ((blank < 0)) && [[ -z "${line//[[:space:]]/}" ]]; then
			blank=$i
		fi
		if [[ "$line" =~ $re ]]; then
			key="${BASH_REMATCH[1]}"
			key="${key%"${key##*[![:space:]]}"}"
			if [[ "${key,,}" == pin ]]; then
				lines[i]="pin: $pin"
				replaced=1
				break
			fi
		fi
	done
	if ((!replaced)); then
		if ((blank >= 0)); then
			lines=("${lines[@]:0:blank}" "pin: $pin" "${lines[@]:blank}")
		else
			lines+=("pin: $pin")
		fi
	fi
	printf '%s\n' "${lines[@]}"
}

cmd_pin() {
	local mode="" clip=1 force=0 inplace=0
	while [[ "${1:-}" == -* ]]; do
		case "$1" in
		--password | --field)
			[[ -z "$mode" || "$mode" == "${1#--}" ]] || npass_die "$(npass_t erro_pin_modos_exclusivos)"
			mode="${1#--}"; shift ;;
		-c | --clip) clip=1; shift ;;
		-f | --force) force=1; shift ;;
		--in-place) inplace=1; shift ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	[[ -n "$mode" ]] || npass_die "$(npass_t erro_pin_modo)"
	local id="${1:-}" logical="${2:-}" digits="${3:-$NPASS_PIN_LENGTH}"
	[[ -z "$id" || -z "$logical" ]] \
		&& npass_die "uso: npass pin (--password | --field) [-c] [-f] [--in-place] ID DIR/PASS [DIGITOS]"
	npass_check_sneaky_path "$logical"
	if [[ ! "$digits" =~ ^[0-9]+$ ]] \
		|| ((digits < NPASS_PIN_MIN_DIGITS || digits > NPASS_PIN_MAX_DIGITS)); then
		npass_die "$(npass_t erro_pin_digitos "$digits" "$NPASS_PIN_MIN_DIGITS" "$NPASS_PIN_MAX_DIGITS")"
	fi
	[[ "$mode" == field && $inplace -eq 1 ]] && npass_die "$(npass_t erro_pin_inplace_field)"

	local dir has_entry=0 existing="" reply
	dir="$(npass_identity_dir "$id")"
	npass_map_resolve "$dir" "$logical" >/dev/null 2>&1 && has_entry=1

	# Read the current content ONLY when it is needed (--field edits it, --in-place
	# keeps part of it). If the entry exists but cannot be decrypted, stop: treating
	# "unreadable" as "empty" would overwrite data we never saw.
	if ((has_entry)) && [[ "$mode" == field || $inplace -eq 1 ]]; then
		existing="$(cmd_show "$id" "$logical")" \
			|| npass_die "$(npass_t erro_pin_ilegivel "$id" "$logical")"
	fi

	if [[ "$mode" == field ]]; then
		((has_entry)) || npass_die "$(npass_t erro_pin_sem_entrada "$id" "$logical")"
		if npass_pin_has_field "$existing" && [[ $force -eq 0 ]]; then
			read -r -p "$(npass_t prompt_pin_existe "$id" "$logical")" reply
			[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
		fi
	elif ((has_entry)) && [[ $inplace -eq 0 && $force -eq 0 ]]; then
		read -r -p "$(npass_t prompt_sobrescrever_existe "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi

	local pin content
	pin="$(npass_pin_digits "$digits")" || exit 1
	if [[ "$mode" == field ]]; then
		content="$(npass_pin_set_field "$existing" "$pin")"
	elif [[ $inplace -eq 1 && $has_entry -eq 1 ]]; then
		content="$(npass_replace_first_line "$existing" "$pin")"
	else
		content="$pin"
	fi
	npass_blob_write "$dir" "$logical" "$content"
	npass_git_commit "$id" "pin"

	if [[ $clip -eq 1 ]]; then
		npass_clip "$pin" "$id: $logical"
	else
		printf '%s\n' "$pin"
	fi
}
