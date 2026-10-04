#!/usr/bin/env bash
# npass-wclip - Windows clipboard extension for npass.
# npass-extension-desc: Extensão clip para windows.
# npass-extension-needs: wclip
#
# Usage:
#   npass wclip ID DIR/PASS
#   npass wclip pass ID DIR/PASS
#   npass wclip CAMPO ID DIR/PASS
#   npass wclip all ID DIR/PASS
#
# Default:
#   copies the password (first line).
#
# This extension is intended for Windows only.

set -u

npass_wclip_die() {
	printf 'npass wclip: %s\n' "$*" >&2
	exit 1
}

command -v wclip >/dev/null 2>&1 ||
	npass_wclip_die "wclip não encontrado"

npass_entry_parse() {
	local content="$1"
	local line key first=1
	local re='^(#[[:space:]]*)?([^:[:space:]#][^:]*):[[:space:]]*(.*)$'

	NPASS_FK=()
	NPASS_FV=()

	while IFS= read -r line; do
		if ((first)); then
			first=0
			continue
		fi

		[[ "$line" == otpauth://* ]] && continue
		[[ "$line" =~ $re ]] || continue

		key="${BASH_REMATCH[2]}"
		key="${key%"${key##*[![:space:]]}"}"

		NPASS_FK+=("${key,,}")
		NPASS_FV+=("${BASH_REMATCH[3]}")
	done <<< "$content"
}

npass_entry_lookup() {
	local want="${1,,}"
	local i hit=-1 hits=0

	# Exact match first.
	for i in "${!NPASS_FK[@]}"; do
		if [[ "${NPASS_FK[i]}" == "$want" ]]; then
			REPLY="${NPASS_FV[i]}"
			return 0
		fi
	done

	# Then unique prefix.
	for i in "${!NPASS_FK[@]}"; do
		if [[ "${NPASS_FK[i]}" == "$want"* ]]; then
			hit=$i
			((hits++))
		fi
	done

	if ((hits == 1)); then
		REPLY="${NPASS_FV[hit]}"
		return 0
	fi

	return 1
}

cmd_wclip() {
	local field="pass"
	local id logical

	case $# in
		2)
			id="$1"
			logical="$2"
			;;

		3)
			field="$1"
			id="$2"
			logical="$3"
			;;

		*)
			npass_wclip_die \
				"uso: npass wclip [CAMPO] ID DIR/PASS"
			;;
	esac

	local content value

	content="$(npass show "$id" "$logical")" ||
		exit 1

	case "${field,,}" in
		pass | password | senha)
			value="${content%%$'\n'*}"
			;;

		all | tudo)
			value="$content"
			;;

		*)
			npass_entry_parse "$content"

			if ! npass_entry_lookup "$field"; then
				npass_wclip_die \
					"campo não encontrado ou ambíguo: $field"
			fi

			value="$REPLY"
			;;
	esac

	[[ -n "$value" ]] ||
		npass_wclip_die "campo vazio: $field"

	printf '%s' "$value" | wclip --secret ||
		npass_wclip_die "não foi possível copiar para o clipboard"
}

cmd_wclip "$@"
