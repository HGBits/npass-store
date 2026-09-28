#!/usr/bin/env bash
# npass - extensions (Model A: external executable, subprocess boundary).
#
# `npass foo args...`, when `foo` isn't a built-in command, looks for an
# executable named `npass-foo` in a dedicated extensions directory (NOT
# a $PATH scan - a scan would make every directory on $PATH part of the
# trust boundary; one directory the user controls is a much smaller
# surface) and, if every gate below passes, execs it with the remaining
# arguments.
#
# Disabled by default (NPASS_ENABLE_EXTENSIONS must be "1"). Even when
# enabled, an extension only runs if ALL of these hold:
#   1. It's a regular file, not a symlink (blocks a swap-the-target
#      trick after the checks below have already run against it).
#   2. It is not group- or other-writable (a shared/misconfigured
#      directory can't let a second local user plant or alter it).
#   3. A detached signature (<file>.sig) exists next to it and
#      cryptographically verifies against that exact file.
#   4. The signing key's fingerprint is among the user's OWN secret
#      keys (`gpg --list-secret-keys`) - not just any key gpg happens
#      to trust or have a public copy of.
#
# That last gate is the one that actually matters: an attacker with
# write access to the extensions directory (a compromised sync target,
# a shared machine, a malicious package) can drop a file, and even sign
# it with their OWN key - the signature will verify just fine
# cryptographically (gate 3 passes). Gate 4 is what stops it: unless
# the attacker also holds one of the fingerprints in your own secret
# keyring - i.e. unless they've already stolen a private key of yours,
# a much higher bar than write access to one directory - the extension
# is refused. Confirmed against a real forged case while building this:
# a file signed by a throwaway keypair, with only that keypair's PUBLIC
# key imported (as an attacker's key realistically would be, if you'd
# ever received anything signed by them), still fails gate 4.

: "${NPASS_ENABLE_EXTENSIONS:=0}"

npass_extensions_dir() {
	printf '%s\n' "${NPASS_EXTENSIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/npass/extensions}"
}

# Non-fatal check: sets NPASS_EXT_REASON and returns 1 on the first
# failing gate, or returns 0 if the file may be executed. Used both by
# the enforcing path (npass_try_extension) and by `extension list`,
# which wants a status per file rather than dying on the first bad one.
NPASS_EXT_REASON=""
npass_extension_check() {
	local path="$1"
	NPASS_EXT_REASON=""

	if [[ -L "$path" ]]; then
		NPASS_EXT_REASON="symlink"
		return 1
	fi
	if [[ ! -f "$path" ]]; then
		NPASS_EXT_REASON="ausente"
		return 1
	fi

	local perms
	perms="$(stat -c '%a' "$path" 2>/dev/null)"
	if [[ -n "$perms" ]]; then
		local group="${perms: -2:1}" other="${perms: -1}"
		if (( (10#$group & 2) || (10#$other & 2) )); then
			NPASS_EXT_REASON="permissao"
			return 1
		fi
	fi

	local sig="$path.sig"
	if [[ ! -f "$sig" ]]; then
		NPASS_EXT_REASON="sem_sig"
		return 1
	fi

	local status_out fpr
	status_out="$("$NPASS_GPG" --batch --status-fd=1 --verify "$sig" "$path" 2>/dev/null)"
	fpr="$(awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}' <<<"$status_out")"
	if [[ -z "$fpr" ]]; then
		NPASS_EXT_REASON="assinatura_invalida"
		return 1
	fi

	local -a own_fprs
	mapfile -t own_fprs < <("$NPASS_GPG" --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10}')
	local k
	for k in "${own_fprs[@]}"; do
		if [[ "$k" == "$fpr" ]]; then
			return 0
		fi
	done
	NPASS_EXT_REASON="chave_nao_e_sua:$fpr"
	return 1
}

# Called from the unknown-command branch of the dispatcher. Returns 1
# (silently - let the caller fall through to "unknown command") only
# when extensions are disabled or no such file exists at all. Any
# other failure is loud: a file WAS found and WAS refused, and staying
# quiet about that would hide a real tampering attempt.
npass_try_extension() {
	local name="$1"; shift
	[[ "$NPASS_ENABLE_EXTENSIONS" == 1 ]] || return 1
	local dir; dir="$(npass_extensions_dir)"
	local path="$dir/npass-$name"
	[[ -e "$path" || -L "$path" ]] || return 1

	if ! npass_extension_check "$path"; then
		case "$NPASS_EXT_REASON" in
		symlink) npass_die "$(npass_t erro_extensao_symlink "$name")" ;;
		permissao) npass_die "$(npass_t erro_extensao_permissao "$name")" ;;
		sem_sig) npass_die "$(npass_t erro_extensao_sem_sig "$name")" ;;
		assinatura_invalida) npass_die "$(npass_t erro_extensao_assinatura_invalida "$name")" ;;
		chave_nao_e_sua:*)
			npass_die "$(npass_t erro_extensao_chave_nao_e_sua "$name" "${NPASS_EXT_REASON#*:}")"
			;;
		*) npass_die "$(npass_t erro_extensao_assinatura_invalida "$name")" ;;
		esac
	fi

	export NPASS_STORE NPASS_GPG NPASS_LANG
	exec "$path" "$@"
}

cmd_extension_sign() {
	local path="$1" keyid="$2"
	[[ -z "$path" ]] && npass_die "uso: npass extension sign CAMINHO [KEYID]"
	npass_gpg_detach_sign "$path" "$path.sig" "$keyid"
	npass_t msg_extensao_assinada "$path"
}

cmd_extension_list() {
	local dir; dir="$(npass_extensions_dir)"
	if [[ ! -d "$dir" ]]; then
		npass_t msg_extensoes_dir_ausente "$dir"
		return 0
	fi
	local f name shopt_nullglob_was_off=1
	shopt -q nullglob && shopt_nullglob_was_off=0
	shopt -s nullglob
	for f in "$dir"/npass-*; do
		[[ "$f" == *.sig ]] && continue
		[[ -f "$f" || -L "$f" ]] || continue
		name="${f##*/npass-}"
		if npass_extension_check "$f"; then
			printf '%s: ok\n' "$name"
		else
			printf '%s: recusada (%s)\n' "$name" "$NPASS_EXT_REASON"
		fi
	done
	[[ $shopt_nullglob_was_off -eq 1 ]] && shopt -u nullglob
	return 0
}

cmd_extension() {
	local sub="$1"; shift
	case "$sub" in
	sign) cmd_extension_sign "$@" ;;
	list) cmd_extension_list "$@" ;;
	*) npass_die "uso: npass extension [sign CAMINHO [KEYID] | list]" ;;
	esac
}
