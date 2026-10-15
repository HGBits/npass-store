#!/usr/bin/env bash
# npass-clip-x11 - X11 clipboard extension for npass.
# npass-extension-desc: Copia senha ou campo para o clipboard do X11 (xclip), para quem ainda usa sessão gráfica X11
# npass-extension-needs: xclip
#
# Requires:
#   - X11
#   - xclip
#
# Usage:
#   npass clip-x11 ID DIR/PASS
#   npass clip-x11 pass ID DIR/PASS
#   npass clip-x11 CAMPO ID DIR/PASS
#   npass clip-x11 all ID DIR/PASS
#
# The default mode copies the password (section "## Senha").
# Field names are case-insensitive and support unique prefixes.

set -u

: "${NPASS_CLIP_TIME:=45}"

npass_clip_x11_die() {
	printf 'npass clip-x11: %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Clipboard backend
# ---------------------------------------------------------------------------

npass_clip_x11() {
	local secret="$1"
	local label="${2:-segredo}"

	command -v xclip >/dev/null 2>&1 ||
		npass_clip_x11_die "xclip não encontrado"

	[[ -n "${DISPLAY:-}" ]] ||
		npass_clip_x11_die "DISPLAY não está definido"

	# xclip must remain alive because X11 clipboard ownership belongs
	# to the process holding the selection.
	#
	# -selection clipboard = CLIPBOARD selection, not PRIMARY
	# -loops 1            = release ownership after one paste request
	# -silent             = no unnecessary stdout/stderr
	printf '%s' "$secret" |
		xclip -selection clipboard -loops 1 -silent &

	local copier=$!

	# Do not let the background process keep command substitutions,
	# pipes or test harnesses waiting on it.
	disown "$copier" 2>/dev/null

	# Backstop timeout. Only clear the clipboard if it still contains
	# exactly the value we put there.
	(
		sleep "$NPASS_CLIP_TIME"

		local current
		current="$(xclip -selection clipboard -o 2>/dev/null)" || exit 0

		if [[ "$current" == "$secret" ]]; then
			# Setting an empty clipboard causes xclip to take ownership
			# temporarily and replace the secret with an empty value.
			printf '%s' '' |
				xclip -selection clipboard -silent 2>/dev/null
		fi
	) >/dev/null 2>&1 </dev/null &

	disown $!

	printf '%s: copiado por %s segundos\n' "$label" "$NPASS_CLIP_TIME" >&2
}

# ---------------------------------------------------------------------------
# Command
# ---------------------------------------------------------------------------

cmd_clip_x11() {
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
			npass_clip_x11_die \
				"uso: npass clip-x11 [CAMPO] ID DIR/PASS"
			;;
	esac

	local value label="$id: $logical"

	# The extension is a separate process and does not parse the entry: the md1
	# format lives only in the core (lib/14-entry.bash), so ask it through its
	# public `get` command. It dies with the right message on a missing field,
	# an empty value or an entry that is not in md1.
	value="$("${NPASS_BIN:-npass}" get "$field" "$id" "$logical")" ||
		exit 1

	case "${field,,}" in
		pass | password | senha | all | tudo) ;;
		*) label+=" [$field]" ;;
	esac

	npass_clip_x11 "$value" "$label"
}

cmd_clip_x11 "$@"
