#!/usr/bin/env bash
# npass - Wayland-only clipboard. No X11 fallback, no xclip, no xdotool,
# no klipper/qdbus branch. If there's no Wayland compositor, npass says
# so and stops instead of silently doing nothing.

: "${NPASS_CLIP_TIME:=45}"

npass_clip() {
	local secret="$1" label="${2:-segredo}"
	command -v wl-copy >/dev/null 2>&1 || npass_die "wl-copy não encontrado (wl-clipboard). npass é Wayland-only."
	[[ -n "$WAYLAND_DISPLAY" ]] || npass_die "sem sessão Wayland ativa (\$WAYLAND_DISPLAY vazio)."

	# --sensitive: hints clipboard managers (cliphist, etc.) not to persist
	# this entry to disk. --paste-once: served exactly once then cleared,
	# so a stray extra paste elsewhere doesn't leave it sitting around.
	# We still additionally clear after NPASS_CLIP_TIME as a backstop for
	# compositors/managers that ignore both hints.
	printf '%s' "$secret" | wl-copy --paste-once --sensitive &
	local copier=$!
	disown "$copier" 2>/dev/null

	(
		sleep "$NPASS_CLIP_TIME"
		# Only clear if nothing else has claimed the clipboard meanwhile.
		if [[ "$(wl-paste --no-newline 2>/dev/null)" == "$secret" ]]; then
			wl-copy --clear 2>/dev/null
		fi
	) & disown

	printf 'Copiado (%s). Limpa em %ss ou no primeiro paste.\n' "$label" "$NPASS_CLIP_TIME" >&2
}
