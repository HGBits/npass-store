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
# The default mode copies the password (first line).
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
# Entry parser
# ---------------------------------------------------------------------------

NPASS_FK=()
NPASS_FV=()

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
	done <<<"$content"
}

npass_entry_lookup() {
	local want="${1,,}"
	local i hit=-1 hits=0

	# Exact key wins.
	for i in "${!NPASS_FK[@]}"; do
		if [[ "${NPASS_FK[i]}" == "$want" ]]; then
			REPLY="${NPASS_FV[i]}"
			return 0
		fi
	done

	# Otherwise accept a unique prefix.
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

	local content value label="$id: $logical"

	# The extension is a separate process, so obtain the entry through
	# npass's public show command rather than depending on internal
	# shell functions from the main program.
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
				npass_clip_x11_die \
					"campo não encontrado ou ambíguo: $field"
			fi

			value="$REPLY"
			label+=" [$field]"
			;;
	esac

	[[ -n "$value" ]] ||
		npass_clip_x11_die "campo vazio: $field"

	npass_clip_x11 "$value" "$label"
}

cmd_clip_x11 "$@"
