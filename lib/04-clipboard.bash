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

	# The timer must not inherit the caller's stdio: otherwise
	# `x=$(npass clip ...)`, a pipe or a test harness would sit waiting for
	# the background sleep to finish (NPASS_CLIP_TIME seconds).
	(
		sleep "$NPASS_CLIP_TIME"
		# Only clear if nothing else has claimed the clipboard meanwhile.
		if [[ "$(wl-paste --no-newline 2>/dev/null)" == "$secret" ]]; then
			wl-copy --clear 2>/dev/null
		fi
	) >/dev/null 2>&1 </dev/null & disown

	npass_t msg_copiado "$label" "$NPASS_CLIP_TIME" >&2
}

# --- clip: choose WHAT gets copied ----------------------------------------------
#
#   npass clip ID DIR/PASS           the password (section "## Senha")   [default]
#   npass clip pass ID DIR/PASS      same, explicit
#   npass clip CAMPO ID DIR/PASS     the value of a "- campo: valor" line
#   npass clip all ID DIR/PASS       the whole entry (the md1 document)
#
# `npass get` takes the same arguments but prints the value on stdout instead
# of copying it: it is what the clipboard extensions (wclip, clip-x11) call, so
# the md1 format is parsed in ONE place (lib/14-entry.bash).
#
# Argument count is what disambiguates: 2 args = ID PATH, 3 args =
# FIELD ID PATH. A field name is matched case-insensitively, exact key
# first, then as a unique prefix ("email" finds "email-alias" when it is
# the only key starting with "email").
#
# `npass get --exact [CAMPO] ID DIR/PASS` drops the unique-prefix fallback:
# CAMPO must equal a key (case-insensitively), or the command fails. It is for
# callers that must not release a different field than the one they named
# (a grant for "email" must not hand out "email-alias"). Only the PREFIX
# fallback changes: the selectors pass/password/senha/all/tudo keep their
# meaning, so a caller that forwards untrusted text as CAMPO must reject
# those words itself. `clip` has no --exact.

NPASS_FK=()
NPASS_FV=()
# 1 (set by `get --exact`): npass_entry_lookup does not fall back to a prefix.
NPASS_LOOKUP_EXACT=0

# Fill NPASS_FK / NPASS_FV (keys lower-cased) from the "## Campos" section of an
# md1 document. Returns the npass_entry_load status (1 = not md1, 2 = invalid).
npass_entry_parse() {
	local l
	npass_entry_load "$1" || return $?
	NPASS_FK=()
	NPASS_FV=()
	for l in "${NPASS_E_FIELDS[@]}"; do
		npass_entry_field_key "$l" || continue
		NPASS_FK+=("$REPLY")
		npass_entry_field_value "$l"
		NPASS_FV+=("$REPLY")
	done
	return 0
}

# npass_entry_lookup FIELD -> value in $REPLY; returns 1 if not found or
# ambiguous (or, with NPASS_LOOKUP_EXACT=1, if there is no exact key). Call
# npass_entry_parse first.
npass_entry_lookup() {
	local want="${1,,}" i hit=-1 hits=0
	for i in "${!NPASS_FK[@]}"; do
		if [[ "${NPASS_FK[i]}" == "$want" ]]; then
			REPLY="${NPASS_FV[i]}"
			return 0
		fi
	done
	((NPASS_LOOKUP_EXACT)) && return 1
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

# npass_entry_pick FIELD CONTENT ID LOGICAL -> the chosen value in $REPLY.
# FIELD: pass (default) | all | the key of a "- chave: valor" line. Dies on a
# non-md1 entry, an unknown/ambiguous field or an empty value.
npass_entry_pick() {
	local field="$1" content="$2" id="$3" logical="$4" value
	npass_entry_require "$id" "$logical" "$content"
	case "${field,,}" in
	pass | password | senha) value="$NPASS_E_PW" ;;
	all | tudo) value="$content" ;;
	*)
		npass_entry_parse "$content"
		if ! npass_entry_lookup "$field"; then
			npass_die "$(npass_t erro_campo_nao_encontrado "$field" "${NPASS_FK[*]:-(nenhum)}")"
		fi
		value="$REPLY"
		;;
	esac
	[[ -n "$value" ]] || npass_die "$(npass_t erro_campo_vazio "$field")"
	REPLY="$value"
}

# [CAMPO] ID DIR/PASS -> field, id, logical (2 args = ID PATH, 3 = FIELD ID PATH)
npass_entry_args() {
	local cmd="$1"
	shift
	case $# in
	2) NPASS_A_FIELD="pass"; NPASS_A_ID="$1"; NPASS_A_LOGICAL="$2" ;;
	3) NPASS_A_FIELD="$1"; NPASS_A_ID="$2"; NPASS_A_LOGICAL="$3" ;;
	*) npass_die "uso: npass $cmd [CAMPO] ID DIR/PASS   (CAMPO: pass [padrão] | all | chave de uma linha '- chave: valor')" ;;
	esac
}

cmd_clip() {
	local content label
	npass_entry_args clip "$@"
	content="$(cmd_show "$NPASS_A_ID" "$NPASS_A_LOGICAL")" || exit 1
	npass_entry_pick "$NPASS_A_FIELD" "$content" "$NPASS_A_ID" "$NPASS_A_LOGICAL"
	label="$NPASS_A_ID: $NPASS_A_LOGICAL"
	case "${NPASS_A_FIELD,,}" in
	pass | password | senha | all | tudo) ;;
	*) label+=" [$NPASS_A_FIELD]" ;;
	esac
	npass_clip "$REPLY" "$label"
}

cmd_get() {
	local content
	NPASS_LOOKUP_EXACT=0
	if [[ "$1" == --exact ]]; then
		NPASS_LOOKUP_EXACT=1
		shift
	fi
	npass_entry_args get "$@"
	content="$(cmd_show "$NPASS_A_ID" "$NPASS_A_LOGICAL")" || exit 1
	npass_entry_pick "$NPASS_A_FIELD" "$content" "$NPASS_A_ID" "$NPASS_A_LOGICAL"
	printf '%s\n' "$REPLY"
}
