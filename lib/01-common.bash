#!/usr/bin/env bash
# npass - core: config, errors, gpg wrapper, secure temp files
# No `set -e`: every fallible call is checked explicitly, because npass
# is sourced by the entry point and a stray -e must never leak into the
# caller's shell (this was a real bug in pass-update.bash).

: "${NPASS_STORE:="$HOME/.npass"}"
: "${NPASS_GPG:="gpg"}"
: "${NPASS_LANG:="${LANG%%.*}"}"
readonly NPASS_VERSION="0.1.0-m2"

# Defense in depth: bash 5.2+ turns on `patsub_replacement`, which makes
# `&` inside the replacement half of ${var/pattern/replacement} mean
# "the matched text" (sed-style), silently changing the result of any
# such substitution that happens to touch a literal `&` (e.g. any URI
# query string). We don't rely on the sed-style behavior anywhere in
# npass; disabling it here means a future ${var/pat/repl} someone adds
# behaves the same on bash 4.x and 5.2+ instead of differing quietly.
shopt -u patsub_replacement 2>/dev/null || true

npass_die() {
	printf 'npass: %s\n' "$*" >&2
	exit 1
}

npass_warn() {
	printf 'npass: %s: %s\n' "$(npass_t rotulo_aviso)" "$*" >&2
}

# One-time hint for people upgrading from the old default location
# ($XDG_DATA_HOME/npass). We never move a password store behind the
# user's back - only say where it is and how to move it. Silent when
# NPASS_STORE was set explicitly or when the new store already exists.
npass_legacy_store_hint() {
	local old="${XDG_DATA_HOME:-$HOME/.local/share}/npass"
	[[ "$NPASS_STORE" == "$HOME/.npass" && ! -e "$NPASS_STORE" && -d "$old" ]] || return 0
	local d
	for d in "$old"/*/; do
		if [[ -f "${d}.gpg-id" ]]; then
			npass_warn "$(npass_t warn_store_legado "$old" "$NPASS_STORE" "$NPASS_STORE" "$old" "$NPASS_STORE")"
			return 0
		fi
	done
}

# Reject any path component that could escape the store via .. or an
# absolute path. Applied to every identity id and every logical path
# before it touches the filesystem.
npass_check_sneaky_path() {
	local p="$1"
	case "$p" in
	'' | . | .. | */../* | ../* | */.. | /*)
		npass_die "$(npass_t erro_caminho_invalido "$p")"
		;;
	esac
	if [[ "$p" == *$'\t'* || "$p" == *$'\n'* ]]; then
		npass_die "$(npass_t erro_caminho_tab "$p")"
	fi
}

# Secure scratch file: 0600, private tmpfs-preferred dir, shredded on exit
# via a trap the caller installs with npass_mktemp_trap.
NPASS_TMPDIR="${XDG_RUNTIME_DIR:-/tmp}/npass.$$"
npass_tmp_init() {
	umask 077
	mkdir -p "$NPASS_TMPDIR" || npass_die "$(npass_t erro_tmp_dir)"
	chmod 700 "$NPASS_TMPDIR"
}

npass_tmp_cleanup() {
	if [[ -d "$NPASS_TMPDIR" ]]; then
		find "$NPASS_TMPDIR" -type f -exec shred -u -- {} + 2>/dev/null
		rm -rf -- "$NPASS_TMPDIR"
	fi
}
trap npass_tmp_cleanup EXIT INT TERM

npass_mktemp() {
	local name="$1"
	mktemp "$NPASS_TMPDIR/${name}.XXXXXX"
}

# --- GPG wrapper ---------------------------------------------------------
# Every call is explicit about stderr: we never silently swallow it,
# unlike the pass-secrets extension this replaces, which hid the real
# decryption failure reason.

npass_gpg_decrypt() {
	local file="$1" err
	if ! [[ -f "$file" ]]; then
		npass_die "$(npass_t erro_arquivo_nao_encontrado "$file")"
	fi
	local errfile
	errfile="$(npass_mktemp gpgerr)"
	if ! "$NPASS_GPG" --quiet --batch --use-agent -d -o - "$file" 2>"$errfile"; then
		err="$(cat "$errfile")"
		npass_die "$(npass_t erro_decrypt "$file" "${err:-$(npass_t erro_gpg_desconhecido)}")"
	fi
}

# npass_gpg_encrypt <recipients_array_name> <out_file>
# reads plaintext from stdin
npass_gpg_encrypt() {
	local -n _recipients="$1"
	local out="$2" tmp errfile
	[[ ${#_recipients[@]} -eq 0 ]] && npass_die "$(npass_t erro_sem_destinatarios)"
	tmp="$(npass_mktemp gpgenc)"
	errfile="$(npass_mktemp gpgerr)"
	local rcpt_args=()
	local r
	for r in "${_recipients[@]}"; do
		rcpt_args+=(-r "$r")
	done
	if ! "$NPASS_GPG" --quiet --batch --yes --use-agent \
		--trust-model always "${rcpt_args[@]}" -e -o "$tmp" 2>"$errfile"; then
		local err
		err="$(cat "$errfile")"
		npass_die "$(npass_t erro_encrypt "$out" "${err:-$(npass_t erro_gpg_desconhecido)}")"
	fi
	mv -f -- "$tmp" "$out" || npass_die "$(npass_t erro_mv_cifrado "$out")"
}

# npass_gpg_detach_sign FILE SIG_OUT [KEYID]
# Shared by .gpg-id signing and extension signing - same operation,
# different target file.
npass_gpg_detach_sign() {
	local file="$1" sig_out="$2" keyid="$3"
	[[ -f "$file" ]] || npass_die "$(npass_t erro_arquivo_nao_encontrado "$file")"
	local -a keyargs=()
	[[ -n "$keyid" ]] && keyargs=(--default-key "$keyid")
	local errfile; errfile="$(npass_mktemp gpgerr)"
	if ! "$NPASS_GPG" --batch --yes --quiet "${keyargs[@]}" --detach-sign -o "$sig_out" "$file" 2>"$errfile"; then
		npass_die "$(npass_t erro_assinar_gpgid "$file" "$(cat "$errfile")")"
	fi
}

npass_read_gpg_id() {
	local dir="$1"
	local f="$dir/.gpg-id"
	[[ -f "$f" ]] || npass_die "$(npass_t erro_sem_gpgid "$dir")"
	npass_verify_gpgid_if_signed "$dir"
	mapfile -t NPASS_RECIPIENTS <"$f"
	# drop blank lines
	local -a filtered=()
	local l
	for l in "${NPASS_RECIPIENTS[@]}"; do
		[[ -n "$l" ]] && filtered+=("$l")
	done
	NPASS_RECIPIENTS=("${filtered[@]}")
	if [[ ${#NPASS_RECIPIENTS[@]} -eq 0 ]]; then
		npass_die "$(npass_t erro_gpgid_vazio "$f")"
	fi
	return 0
}
