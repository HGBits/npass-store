#!/usr/bin/env bash
# Official extensions: system-wide, XDG-discovered, signed by the packaged trust root.

npass_xdg_data_dirs() {
	local dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" base
	while IFS= read -r base; do
		[[ -n "$base" && "$base" == /* ]] || continue
		while [[ "$base" != "/" && "$base" == */ ]]; do base="${base%/}"; done
		[[ -n "$base" ]] || base="/"
		printf '%s\n' "$base"
	done < <(tr ':' '\n' <<<"$dirs")
}

npass_extensions_dir() {
	local base
	while IFS= read -r base; do printf '%s/npass/extensions\n' "$base"; done < <(npass_xdg_data_dirs)
}

npass_extension_secure_object() {
	local PATH=/usr/bin:/bin
	local path="$1" kind="$2" meta uid mode
	[[ ! -L "$path" ]] || return 1
	case "$kind" in
		dir) [[ -d "$path" ]] || return 1 ;;
		file) [[ -f "$path" ]] || return 1 ;;
	esac
	meta="$(stat -c '%u:%a' -- "$path" 2>/dev/null)" || return 1
	uid="${meta%%:*}"; mode="${meta#*:}"
	[[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
	(( (8#$mode & 0022) == 0 )) || return 1
	if [[ "$kind" == file ]]; then (( (8#$mode & 07000) == 0 )) || return 1; fi
}

npass_extension_secure_ancestors() {
	local PATH=/usr/bin:/bin
	local current="$1"
	local meta uid mode
	[[ "$current" != *"/../"* && "$current" != */.. && "$current" != *"/./"* && "$current" != */. && "$current" != *"//"* ]] || return 1
	while [[ "$current" != "/" ]]; do
		[[ -d "$current" && ! -L "$current" ]] || return 1
		meta="$(stat -c '%u:%a' -- "$current" 2>/dev/null)" || return 1
		uid="${meta%%:*}"; mode="${meta#*:}"
		[[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
		(( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
		current="${current%/*}"
		[[ -n "$current" ]] || current="/"
	done
	npass_extension_secure_object "/" dir
}

npass_extension_verify_signature() {
	local PATH=/usr/bin:/bin
	local path="$1" sig="$2" key="$3"
	local gh nprim fpr status line signer primary gpg_bin gpgconf_bin
	local -a fields=()
	gpg_bin="$(command -p -v gpg)" || return 1
	gpgconf_bin="$(command -p -v gpgconf)" || true
	gh="$(mktemp -d "${TMPDIR:-/tmp}/npass-ext-gpg.XXXXXX")" || return 1
	chmod 700 "$gh"
	if ! GNUPGHOME="$gh" "$gpg_bin" --batch --quiet --import "$key" 2>/dev/null; then
		rm -rf -- "$gh"; return 1
	fi
	nprim="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
	if [[ "$nprim" != 1 ]]; then
		if [[ -n "$gpgconf_bin" ]]; then GNUPGHOME="$gh" "$gpgconf_bin" --kill all 2>/dev/null || true; fi
		rm -rf -- "$gh"; return 1
	fi
	fpr="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
	status="$(GNUPGHOME="$gh" "$gpg_bin" --batch --no-auto-key-retrieve --status-fd=1 --verify "$sig" "$path" 2>/dev/null)" || {
		if [[ -n "$gpgconf_bin" ]]; then GNUPGHOME="$gh" "$gpgconf_bin" --kill all 2>/dev/null || true; fi
		rm -rf -- "$gh"; return 1
	}
	line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status" | head -n1)"
	read -r -a fields <<<"$line"
	signer="${fields[2]:-}"; primary="${fields[11]:-$signer}"
	if [[ -n "$gpgconf_bin" ]]; then GNUPGHOME="$gh" "$gpgconf_bin" --kill all 2>/dev/null || true; fi
	rm -rf -- "$gh"
	[[ -n "$fpr" && "$primary" == "$fpr" && -n "$signer" ]] || return 1
	! grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$status"
}

NPASS_EXT_REASON=""
npass_extension_check() {
	local path="$1" key="$2" dir sig npass_dir base
	NPASS_EXT_REASON=""
	dir="${path%/*}"; npass_dir="${dir%/*}"; base="${npass_dir%/*}"
	sig="$path.sig"
	[[ ! -L "$path" ]] || { NPASS_EXT_REASON="symlink"; return 1; }
	[[ -f "$path" && -x "$path" ]] || { NPASS_EXT_REASON="ausente"; return 1; }
	[[ ! -L "$sig" && -f "$sig" ]] || { NPASS_EXT_REASON="sem_sig"; return 1; }
	if ! npass_extension_secure_ancestors "$base" ||
		! npass_extension_secure_object "$npass_dir" dir ||
		! npass_extension_secure_object "$dir" dir ||
		! npass_extension_secure_object "$key" file ||
		! npass_extension_secure_object "$path" file ||
		! npass_extension_secure_object "$sig" file; then
		NPASS_EXT_REASON="permissao"; return 1
	fi
	if ! npass_extension_verify_signature "$path" "$sig" "$key"; then
		NPASS_EXT_REASON="assinatura_invalida"; return 1
	fi
	return 0
}

npass_try_extension() {
	local name="$1" base dir key path
	shift
	[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
	while IFS= read -r base; do
		dir="$base/npass/extensions"; path="$dir/npass-$name"
		[[ -e "$path" || -L "$path" ]] || continue
		key="$base/npass/extension-signing-key.asc"
		if ! npass_extension_check "$path" "$key"; then
			case "$NPASS_EXT_REASON" in
				symlink) npass_die "$(npass_t erro_extensao_symlink "$name")" ;;
				permissao) npass_die "$(npass_t erro_extensao_permissao "$name")" ;;
				sem_sig) npass_die "$(npass_t erro_extensao_sem_sig "$name")" ;;
				*) npass_die "$(npass_t erro_extensao_assinatura_invalida "$name")" ;;
			esac
		fi
		local self
		self="$(readlink -f -- "$0" 2>/dev/null)"
		[[ -x "$self" ]] || self="$(command -v npass 2>/dev/null)"
		export NPASS_STORE NPASS_GPG NPASS_LANG
		[[ -x "$self" ]] && export NPASS_BIN="$self"
		npass_tmp_cleanup
		exec "$path" "$@"
	done < <(npass_xdg_data_dirs)
	return 1
}

cmd_extension_list() {
	local base dir key f name found=0
	declare -A seen=()
	while IFS= read -r base; do
		dir="$base/npass/extensions"; [[ -d "$dir" ]] || continue
		key="$base/npass/extension-signing-key.asc"
		shopt -s nullglob
		for f in "$dir"/npass-*; do
			[[ "$f" == *.sig || ( ! -f "$f" && ! -L "$f" ) ]] && continue
			found=1
			name="${f##*/npass-}"
			if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
				printf '%s: recusada (nome_invalido)\n' "$name"
				continue
			fi
			[[ -n "${seen[$name]:-}" ]] && continue
			seen[$name]=1
			if npass_extension_check "$f" "$key"; then
				printf '%s: ok\n' "$name"
			else
				printf '%s: recusada (%s)\n' "$name" "$NPASS_EXT_REASON"
			fi
		done
		shopt -u nullglob
	done < <(npass_xdg_data_dirs)
	((found)) || npass_t msg_extensoes_dir_ausente "$(npass_extensions_dir | paste -sd' ')"
	return 0
}

cmd_extension() {
	local sub="${1-}"; shift || true
	case "$sub" in
		list) cmd_extension_list "$@" ;;
		*) npass_die "uso: npass extension list" ;;
	esac
}
