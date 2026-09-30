#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_FAKE_TOMB_STATE="$BATS_TEST_TMPDIR/fake-tomb"
	export NPASS_TOMB_KEY_DIR="$BATS_TEST_TMPDIR/tomb-keys"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	mkdir -p "$NPASS_STORE" "$BATS_TEST_TMPDIR/bin" "$NPASS_FAKE_TOMB_STATE" "$NPASS_TOMB_KEY_DIR"
	cat >"$BATS_TEST_TMPDIR/bin/tomb" <<'EOF'
#!/usr/bin/env bash
set -u
state="${NPASS_FAKE_TOMB_STATE:?}"
cmd="$1"
shift

tomb_name_from_file() {
	local f="$1"
	f="${f##*/}"
	printf '%s\n' "${f%.tomb}"
}

case "$cmd" in
dig)
	file="$1"
	shift
	: >"$file"
	;;
forge)
	key="$1"
	shift
	printf 'fake tomb key\n' >"$key"
	;;
lock)
	# The fake Tomb only needs the image and key to exist.
	;;
open)
	file="$1"
	shift
	mount=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-g) mount="$2"; shift 2 ;;
		-k) shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "$mount" ]] || exit 2
	name="$(tomb_name_from_file "$file")"
	backing="$state/$name"
	mkdir -p "$backing" "$mount"
	if [[ -e "$backing/.map.gpg" ]]; then
		mv "$backing/.map.gpg" "$mount/.map.gpg"
	fi
	if [[ -d "$backing/blobs" ]]; then
		mv "$backing/blobs" "$mount/blobs"
	fi
	printf '%s\n' "$mount" >"$state/$name.mount"
	printf x >"$mount/.fake-mounted"
	;;
close)
	name="$(tomb_name_from_file "$1")"
	mount="$(cat "$state/$name.mount")"
	backing="$state/$name"
	mkdir -p "$backing"
	rm -f "$mount/.fake-mounted"
	if [[ -e "$mount/.map.gpg" ]]; then
		mv "$mount/.map.gpg" "$backing/.map.gpg"
	fi
	if [[ -d "$mount/blobs" ]]; then
		mv "$mount/blobs" "$backing/blobs"
	fi
	;;
*)
	exit 2
	;;
esac
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/tomb"

	cat >"$BATS_TEST_TMPDIR/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-q" ]] || exit 2
dir="$2"
[[ -f "$dir/.fake-mounted" ]]
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/mountpoint"
}

@test "create abre a identidade e move mapa e blobs para o Tomb" {
	"$NPASS" init personal "$FPR"
	printf 'segredo\nsegredo\n' | "$NPASS" insert personal email/gmail

	run "$NPASS" tomb create personal
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.npass.tomb" ]
	[ -L "$NPASS_STORE/personal/.map.gpg" ]
	[ -L "$NPASS_STORE/personal/blobs" ]
	[ -f "$NPASS_STORE/personal/.npass-tomb/.map.gpg" ]
	[ -d "$NPASS_STORE/personal/.npass-tomb/blobs" ]

	run "$NPASS" show personal email/gmail
	[ "$status" -eq 0 ]
	[ "$output" = "segredo" ]
}

@test "close bloqueia acesso e open restaura acesso" {
	"$NPASS" init personal "$FPR"
	printf 'segredo\nsegredo\n' | "$NPASS" insert personal email/gmail
	"$NPASS" tomb create personal

	run "$NPASS" tomb close personal
	[ "$status" -eq 0 ]

	run "$NPASS" tomb status personal
	[ "$status" -eq 0 ]
	[[ "$output" == *"Tomb fechado"* ]]

	run "$NPASS" show personal email/gmail
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade 'personal' está fechada"* ]]

	run "$NPASS" ls personal
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade 'personal' está fechada"* ]]

	run "$NPASS" tomb open personal
	[ "$status" -eq 0 ]

	run "$NPASS" show personal email/gmail
	[ "$status" -eq 0 ]
	[ "$output" = "segredo" ]
}

@test "identidade sem Tomb continua funcionando" {
	"$NPASS" init work "$FPR"
	printf 'abc\nabc\n' | "$NPASS" insert work aws/root

	run "$NPASS" tomb status work
	[ "$status" -eq 0 ]
	[[ "$output" == *"sem proteção Tomb"* ]]

	run "$NPASS" show work aws/root
	[ "$status" -eq 0 ]
	[ "$output" = "abc" ]
}

@test "create duplicado é recusado" {
	"$NPASS" init personal "$FPR"
	"$NPASS" tomb create personal

	run "$NPASS" tomb create personal
	[ "$status" -ne 0 ]
	[[ "$output" == *"já possui um Tomb"* ]]
}

@test "tomb list mostra somente identidades protegidas e seus estados" {
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR"
	"$NPASS" tomb create personal
	"$NPASS" tomb close personal

	run "$NPASS" tomb list
	[ "$status" -eq 0 ]
	[[ "$output" == *"personal - fechado"* ]]
	[[ "$output" != *"work"* ]]
}

@test "git rastreia o artefato Tomb sem rastrear seus blobs internos" {
	"$NPASS" init personal "$FPR"
	printf 'segredo\nsegredo\n' | "$NPASS" insert personal email/gmail
	"$NPASS" tomb create personal
	"$NPASS" tomb close personal

	run "$NPASS" git ls-files --stage -- personal/blobs
	[ "$status" -eq 0 ]
	[[ "$output" == *"120000"* ]]
	[[ "$output" == *
personal/blobs'* ]]
	[[ "$output" != *".gpg"* ]]

	run "$NPASS" git ls-files --stage -- personal/.map.gpg
	[ "$status" -eq 0 ]
	[[ "$output" == *"120000"* ]]
	[[ "$output" == *
personal/.map.gpg'* ]]
}
