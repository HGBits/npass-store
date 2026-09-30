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
# Every store is a git repository from the moment it is created
# (npass_git_ensure, called by `init`), and every mutating command
# commits automatically. One repository at the store root; commits are
# scoped per identity with a pathspec so one identity's history never
# absorbs another's changes.
#
# The tree itself will still show file PATHS changing (identity-dir/
# blobs/<opaque-hex>.gpg, identity-dir/.map.gpg) - that's unavoidable
# and fine, since the blob filename carries no information.

npass_git_is_repo() {
	[[ -d "$NPASS_STORE/.git" ]]
}

# Create the store repository if it does not exist yet. Idempotent and
# cheap when the repo is already there. Returns 1 (never dies) if git is
# missing or init fails, so password operations keep working without it.
npass_git_ensure() {
	npass_git_is_repo && return 0
	command -v git >/dev/null 2>&1 || return 1
	mkdir -p -- "$NPASS_STORE" || return 1
	git -C "$NPASS_STORE" init -q 2>/dev/null || return 1
	# Repo-local identity only when the user has none configured anywhere,
	# so the very first automatic commit cannot fail on "who are you?".
	git -C "$NPASS_STORE" config --get user.name >/dev/null 2>&1 \
		|| git -C "$NPASS_STORE" config user.name "npass"
	git -C "$NPASS_STORE" config --get user.email >/dev/null 2>&1 \
		|| git -C "$NPASS_STORE" config user.email "npass@localhost"
	printf '%s\n' '.map.lock' 'extensions/' >"$NPASS_STORE/.gitignore"
	git -C "$NPASS_STORE" add -- .gitignore 2>/dev/null
	git -C "$NPASS_STORE" commit -q --no-verify --no-gpg-sign \
		-m "init: store" -- .gitignore 2>/dev/null
	return 0
}

# npass_git_commit ID ACTION
# Never fatal. Creates the repo on demand (stores created before this
# feature get one on their first mutating command), stages only that
# identity, and commits only when something is actually staged. A failed
# commit is reported as a warning, not swallowed and not fatal.
npass_git_commit() {
	local id="$1" action="$2" errfile
	npass_git_ensure || return 0
	git -C "$NPASS_STORE" add -A -- "$id" 2>/dev/null
	if ! git -C "$NPASS_STORE" diff --cached --quiet -- "$id" 2>/dev/null; then
		errfile="$(npass_mktemp giterr)"
		if ! git -C "$NPASS_STORE" commit -q --no-verify --no-gpg-sign \
			-m "$action: $id" -- "$id" 2>"$errfile"; then
			npass_warn "$(npass_t warn_git_commit "$(head -n 1 "$errfile")")"
		fi
	fi
	return 0
}

# npass nlog - show the last 20 commits in compact form.
cmd_nlog() {
	npass_git_ensure || npass_die "$(npass_t erro_git_indisponivel)"
	git -C "$NPASS_STORE" log --oneline -20
}

# npass nloglong - show files modified by commits from the last 6 months.
cmd_nloglong() {
	npass_git_ensure || npass_die "$(npass_t erro_git_indisponivel)"
	git -C "$NPASS_STORE" log --diff-filter=M --name-only --since="6 months ago"
}

# npass git ARGS... - direct passthrough, e.g. `npass git log --stat`,
# `npass git remote add origin ...`. Makes sure the repo exists first.
cmd_git() {
	npass_git_ensure || npass_die "$(npass_t erro_git_indisponivel)"
	git -C "$NPASS_STORE" "$@"
}
