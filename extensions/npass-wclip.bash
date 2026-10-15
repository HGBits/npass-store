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
#   copies the password (section "## Senha").
#
# This extension is intended for Windows only.

set -u

npass_wclip_die() {
	printf 'npass wclip: %s\n' "$*" >&2
	exit 1
}

command -v wclip >/dev/null 2>&1 ||
	npass_wclip_die "wclip não encontrado"

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

	local value

	# The extension does not parse the entry: the md1 format lives only in the
	# core, so ask it through its public `get` command (it reports a missing
	# field, an empty value or a non-md1 entry itself).
	value="$("${NPASS_BIN:-npass}" get "$field" "$id" "$logical")" ||
		exit 1

	printf '%s' "$value" | wclip --secret ||
		npass_wclip_die "não foi possível copiar para o clipboard"
}

cmd_wclip "$@"
