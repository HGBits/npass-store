#!/usr/bin/env bash
# npass - entry point and command dispatch.

npass_main() {
	npass_tmp_init
	local cmd="$1"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	init) npass_identity_init "$@" ;;
	show) cmd_show "$@" ;;
	insert | add) cmd_insert "$@" ;;
	rm | remove | delete) cmd_rm "$@" ;;
	mv | rename) cmd_mv "$@" ;;
	ls | list) cmd_ls "$@" ;;
	generate | gen) cmd_generate "$@" ;;
	edit) cmd_edit "$@" ;;
	update) cmd_update "$@" ;;
	clip)
		local id="$1" logical="$2"
		local secret; secret="$(cmd_show "$id" "$logical")" || exit 1
		npass_clip "$secret" "$id: $logical"
		;;
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
	'' | help | -h | --help)
		cat <<-_EOF
			npass $NPASS_VERSION - Wayland-native password store com resolução de identidade

			Uso: npass COMANDO ID DIR/PASS [...]

			  init ID RECIPIENT...     cria uma identidade nova
			  show ID DIR/PASS         mostra um segredo
			  clip ID DIR/PASS         copia para a área de transferência (Wayland)
			  insert [-f] ID DIR/PASS  insere/atualiza um segredo
			  rm [-f] ID DIR/PASS      remove um segredo
			  mv ID DIR/PASS DEST      renomeia (mesma identidade) ou move (entre identidades)
			  ls ID [DIR]              lista os caminhos lógicos de uma identidade
			  generate [-n|-c|-f] [--in-place] ID DIR/PASS [LEN]   gera senha aleatória
			  edit ID DIR/PASS         edita o conteúdo bruto no \$EDITOR
			  update [opts] ID PATTERN...   rotaciona senhas em massa (veja 'npass update -h')
			  otp ID DIR/PASS          gera o código OTP (TOTP/HOTP) do segredo
			  otp insert [-f] ID DIR/PASS   insere/atualiza a URI OTP (interativo)
			  otp uri [-c|-q] ID DIR/PASS   mostra a URI OTP, copia, ou exibe QR
			  otp clip ID DIR/PASS     copia o código OTP para a área de transferência

			Não existe modo de caminho físico "clássico": todo comando exige ID.
		_EOF
		;;
	*) npass_die "comando desconhecido: $cmd (veja 'npass help')" ;;
	esac
}

npass_main "$@"
