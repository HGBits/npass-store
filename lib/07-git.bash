#!/usr/bin/env bash
# npass - git integration.
#
# Critical rule: a git commit MESSAGE must never contain a logical
# secret path ("email/gmail"). That's exactly the kind of leak the
# identity/map redesign exists to prevent - pass upstream writes the
# pass-name straight into the commit message ("Add given password for
# $path to store."), which defeats any name-obscuring the moment
# someone runs `git log`. Commits here are staged per-identity and
# labeled only with the identity id and a generic action verb.
#
# The tree itself will still show file PATHS changing (identity-dir/
# blobs/<opaque-hex>.gpg, identity-dir/.map.gpg) - that's unavoidable
# and fine, since the blob filename carries no information.

npass_git_is_repo() {
	[[ -d "$NPASS_STORE/.git" ]]
}

# npass_git_commit ID ACTION
# No-op (and never fatal) if $NPASS_STORE isn't a git repo, or if there
# is nothing staged to commit under that identity.
npass_git_commit() {
	local id="$1" action="$2"
	npass_git_is_repo || return 0
	git -C "$NPASS_STORE" add -A -- "$id" 2>/dev/null
	if ! git -C "$NPASS_STORE" diff --cached --quiet -- "$id" 2>/dev/null; then
		git -C "$NPASS_STORE" commit -q -m "$action: $id" -- "$id" 2>/dev/null
	fi
}

# npass git ARGS... - direct passthrough, e.g. `npass git init`,
# `npass git log --stat`, `npass git remote add origin ...`.
cmd_git() {
	mkdir -p "$NPASS_STORE"
	git -C "$NPASS_STORE" "$@"
}
