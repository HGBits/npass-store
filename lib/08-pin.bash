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
		npass_entry_require "$id" "$logical" "$existing"
	fi

	if [[ "$mode" == field ]]; then
		((has_entry)) || npass_die "$(npass_t erro_pin_sem_entrada "$id" "$logical")"
		if npass_entry_field_has pin && [[ $force -eq 0 ]]; then
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
		npass_entry_field_set pin "$pin"
		content="$(npass_entry_render)"
	elif [[ $inplace -eq 1 && $has_entry -eq 1 ]]; then
		content="$(npass_entry_with_password "$existing" "$pin")"
	else
		content="$(npass_entry_new "$pin")"
	fi
	npass_blob_write "$dir" "$logical" "$content"
	npass_git_commit "$id" "pin"

	if [[ $clip -eq 1 ]]; then
		npass_clip "$pin" "$id: $logical"
	else
		printf '%s\n' "$pin"
	fi
}
