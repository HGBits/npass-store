#!/usr/bin/env bash
# npass - entry point and command dispatch.

npass_main() {
	npass_tmp_init
	npass_legacy_store_hint
	local cmd="$1"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	init) npass_identity_init "$@" ;;
	identities | ids) cmd_identities "$@" ;;
	show) cmd_view "$@" ;;
	insert | add) cmd_insert "$@" ;;
	rm | remove | delete) cmd_rm "$@" ;;
	mv | rename) cmd_mv "$@" ;;
	ls | list) cmd_ls "$@" ;;
	open) cmd_open "$@" ;;
	tree) npass_die "$(npass_t erro_tree_movido)" ;;
	generate | gen) cmd_generate "$@" ;;
	diceware) cmd_diceware "$@" ;;
	memorable) cmd_memorable "$@" ;;
	edit) cmd_edit "$@" ;;
	update) cmd_update "$@" ;;
	find) cmd_find "$@" ;;
	grep) cmd_grep "$@" ;;
	git) cmd_git "$@" ;;
	log) cmd_log "$@" ;;
	loglong) cmd_loglong "$@" ;;
	sign) cmd_sign "$@" ;;
	extension) cmd_extension "$@" ;;
	clip) cmd_clip "$@" ;;
	get) cmd_get "$@" ;;
	pin) cmd_pin "$@" ;;
	backup) cmd_backup "$@" ;;
	otp)
		local sub="$1"; shift
		case "$sub" in
		insert | add) cmd_otp_insert "$@" ;;
		uri) cmd_otp_uri "$@" ;;
		clip) cmd_otp_clip "$@" ;;
		validate) cmd_otp_validate "$@" ;;
		code | show) cmd_otp_code "$@" ;;
		'') npass_die "uso: npass otp [insert|uri|clip|validate] ID DIR/PASS" ;;
		*) cmd_otp_code "$sub" "$@" ;; # `npass otp ID DIR/PASS` (default action)
		esac
		;;
	'' | help | -h | --help) cmd_help "$@" ;;
	# Importing lives in the npass-import extension now; say so instead of
	# a bare "unknown command" for the two names people already know.
	migrate | migrate-secrets) npass_die "$(npass_t erro_migrate_movido "$cmd")" ;;
	*) npass_try_extension "$cmd" "$@" || npass_die "$(npass_t erro_comando_desconhecido "$cmd")" ;;
	esac
}

npass_main "$@"
