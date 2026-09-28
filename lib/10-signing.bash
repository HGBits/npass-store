#!/usr/bin/env bash
# npass - .gpg-id signing and verification.
#
# .gpg-id lists who a secret is encrypted to. If an attacker with
# write access to the store (a compromised sync target, a malicious
# git remote, a shared backup) can replace it silently, every future
# `insert`/`generate`/`edit` in that identity gets encrypted to the
# attacker's key instead of yours - and nothing about the ciphertext
# itself would look wrong.
#
# Signing is opt-in per identity: `npass init --sign` or `npass sign`
# writes a detached signature (.gpg-id.sig) over .gpg-id. From then on,
# npass_read_gpg_id verifies that signature on every read and refuses
# to proceed if it's missing content or doesn't verify. An identity
# that was never signed has no .gpg-id.sig and is read exactly as
# before - signing never becomes mandatory retroactively.

npass_gpgid_sig_path() {
	printf '%s\n' "$1/.gpg-id.sig"
}

# npass_sign_gpgid ID_DIR [KEYID]
npass_sign_gpgid() {
	local dir="$1" keyid="$2"
	local f="$dir/.gpg-id"
	local sig; sig="$(npass_gpgid_sig_path "$dir")"
	npass_gpg_detach_sign "$f" "$sig" "$keyid"
}

# Called from npass_read_gpg_id before its content is trusted. A no-op
# if the identity was never signed (no .gpg-id.sig present).
npass_verify_gpgid_if_signed() {
	local dir="$1"
	local f="$dir/.gpg-id"
	local sig; sig="$(npass_gpgid_sig_path "$dir")"
	[[ -f "$sig" ]] || return 0
	local errfile; errfile="$(npass_mktemp gpgerr)"
	if ! "$NPASS_GPG" --batch --quiet --verify "$sig" "$f" 2>"$errfile"; then
		npass_die "$(npass_t erro_assinatura_invalida "$dir" "$(cat "$errfile")")"
	fi
	return 0
}

# npass sign ID [KEYID] - (re)sign an existing identity's .gpg-id,
# e.g. after rotating recipients, or to opt an old identity in.
cmd_sign() {
	local id="$1" keyid="$2"
	[[ -z "$id" ]] && npass_die "uso: npass sign ID [KEYID]"
	local dir; dir="$(npass_identity_dir "$id")"
	npass_sign_gpgid "$dir" "$keyid"
	npass_git_commit "$id" "sign"
	npass_t msg_assinado "$id"
}
