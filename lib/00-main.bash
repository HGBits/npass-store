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
	show) cmd_show "$@" ;;
	insert | add) cmd_insert "$@" ;;
	rm | remove | delete) cmd_rm "$@" ;;
	mv | rename) cmd_mv "$@" ;;
	ls | list) cmd_ls "$@" ;;
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
	pin) cmd_pin "$@" ;;
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
			  init --sign[=KEYID] ID RECIPIENT...   idem, já assinando o .gpg-id
			  identities               lista as identidades e quantas senhas cada uma tem
			  sign ID [KEYID]          assina (ou reassina) o .gpg-id de uma identidade
			  extension sign CAMINHO [KEYID]   assina um executável de extensão
			  extension list           lista extensões e se cada uma passaria nas checagens
			  show ID DIR/PASS         mostra um segredo
			  clip [CAMPO] ID DIR/PASS copia a senha (padrão), 'all' ou um campo 'chave: valor'
			  pin (--password|--field) [-c|-f] [--in-place] ID DIR/PASS [N]   gera um PIN numérico: como a senha ou como o campo 'pin:'
			  insert [-f] ID DIR/PASS  insere/atualiza um segredo
			  insert --batch [-f] ID   grava vários (registros CAMINHO\\0CONTEÚDO\\0 no stdin)
			  rm [-f] ID DIR/PASS      remove um segredo
			  mv ID DIR/PASS DEST      renomeia (mesma identidade) ou move (entre identidades)
			  ls ID [DIR]              lista os caminhos lógicos de uma identidade
			  generate [-n|-c|-f] [--in-place] ID DIR/PASS [LEN]   gera senha aleatória
			  diceware [-c|-f] [--in-place] [-s SEP] ID DIR/PASS [N]   frase de N palavras (EFF Large); mostra as ALTURAS para anotar
			  memorable [-c|-f] [--in-place] [-s SEP] [-l short|short1|short2] ID DIR/PASS [N]   frase memorável (palavras curtas), sem alturas
			  edit ID DIR/PASS         edita o conteúdo bruto no \$EDITOR
			  update [opts] ID PATTERN...   rotaciona senhas em massa (veja 'npass update -h')
			  find ID PADRÃO           busca caminhos lógicos que casam PADRÃO
			  grep ID [OPÇÕES] PADRÃO decifra e busca PADRÃO no conteúdo de cada entrada
			  git ARGS...              passthrough para git dentro do store (repositório criado no primeiro init)
			  log                     mostra os 20 últimos commits em formato resumido
			  loglong                 mostra arquivos modificados nos últimos 6 meses
			  otp ID DIR/PASS          gera o código OTP (TOTP/HOTP) do segredo
			  otp insert [-f] ID DIR/PASS   insere/atualiza a URI OTP (interativo)
			  otp uri [-c|-q] ID DIR/PASS   mostra a URI OTP, copia, ou exibe QR
			  otp clip ID DIR/PASS     copia o código OTP para a área de transferência

			Não existe modo de caminho físico "clássico": todo comando exige ID.
		_EOF
		;;
	# Importing lives in the npass-import extension now; say so instead of
	# a bare "unknown command" for the two names people already know.
	migrate | migrate-secrets) npass_die "$(npass_t erro_migrate_movido "$cmd")" ;;
	*) npass_try_extension "$cmd" "$@" || npass_die "$(npass_t erro_comando_desconhecido "$cmd")" ;;
	esac
}

npass_main "$@"
