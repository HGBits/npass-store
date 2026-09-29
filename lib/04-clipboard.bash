#!/usr/bin/env bash
# npass - Wayland-only clipboard. No X11 fallback, no xclip, no xdotool,
# no klipper/qdbus branch. If there's no Wayland compositor, npass says
# so and stops instead of silently doing nothing.

: "${NPASS_CLIP_TIME:=45}"

npass_clip() {
	local secret="$1" label="${2:-segredo}"
	command -v wl-copy >/dev/null 2>&1 || npass_die "$(npass_t erro_wlcopy)"
	[[ -n "$WAYLAND_DISPLAY" ]] || npass_die "$(npass_t erro_sem_wayland)"

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

	npass_t msg_copiado "$label" "$NPASS_CLIP_TIME" >&2
}

# --- clip: choose WHAT gets copied ----------------------------------------------
#
#   npass clip ID DIR/PASS           the password (first line)   [default]
#   npass clip pass ID DIR/PASS      same, explicit
#   npass clip CAMPO ID DIR/PASS     the value of a "campo: valor" line
#   npass clip all ID DIR/PASS       the whole entry (old behaviour)
#
# Argument count is what disambiguates: 2 args = ID PATH, 3 args =
# FIELD ID PATH. A field name is matched case-insensitively, exact key
# first, then as a unique prefix ("email" finds "email-alias" when it is
# the only key starting with "email").

NPASS_FK=()
NPASS_FV=()

# Parse the lines AFTER the first (the first is the password) that look
# like "key: value" into NPASS_FK / NPASS_FV (keys lower-cased). A leading
# "# " is accepted because migrate-secrets writes its note lines that way
# ("# email-alias: ...", "# nome-real: ...").
npass_entry_parse() {
	local content="$1" line key first=1
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

# npass_entry_lookup FIELD -> value in $REPLY; returns 1 if not found or
# ambiguous. Call npass_entry_parse first.
npass_entry_lookup() {
	local want="${1,,}" i hit=-1 hits=0
	for i in "${!NPASS_FK[@]}"; do
		if [[ "${NPASS_FK[i]}" == "$want" ]]; then
			REPLY="${NPASS_FV[i]}"
			return 0
		fi
	done
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

cmd_clip() {
	local field="pass" id logical
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
	*) npass_die "uso: npass clip [CAMPO] ID DIR/PASS   (CAMPO: pass [padrão] | all | chave de uma linha 'chave: valor')" ;;
	esac
	local content value label="$id: $logical"
	content="$(cmd_show "$id" "$logical")" || exit 1
	case "${field,,}" in
	pass | password | senha) value="${content%%$'\n'*}" ;;
	all | tudo) value="$content" ;;
	*)
		npass_entry_parse "$content"
		if ! npass_entry_lookup "$field"; then
			npass_die "$(npass_t erro_campo_nao_encontrado "$field" "${NPASS_FK[*]:-(nenhum)}")"
		fi
		value="$REPLY"
		label+=" [$field]"
		;;
	esac
	[[ -n "$value" ]] || npass_die "$(npass_t erro_campo_vazio "$field")"
	npass_clip "$value" "$label"
}
