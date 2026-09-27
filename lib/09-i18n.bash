#!/usr/bin/env bash
# npass - i18n for short runtime messages (errors, warnings, success
# confirmations, y/N prompts). Scope decision: usage/help text ("uso:
# npass ...", the multi-line help heredocs) stays Portuguese-only for
# now - duplicating full command reference text per language is a
# maintenance burden with little payoff; that reference lives in the
# man page instead, which can be translated independently if needed.
#
# Convention for table entries (matters for whether they carry a
# trailing \n):
#   - die/warn/prompt entries: NO trailing \n. Used as
#     npass_die "$(npass_t key args...)" or inside a read -r -p "$(...)".
#   - direct-print success entries: DO end in \n, since npass_t is
#     called bare as the print statement itself: `npass_t msg_salvo ...`

declare -gA NPASS_MSG_PT=(
	[erro_caminho_invalido]="caminho inválido: '%s'"
	[erro_caminho_tab]="caminho inválido (contém tab/newline): '%s'"
	[erro_tmp_dir]="não foi possível criar diretório temporário seguro"
	[erro_arquivo_nao_encontrado]="arquivo não encontrado: %s"
	[erro_decrypt]="falha ao descriptografar '%s': %s"
	[erro_sem_destinatarios]="nenhum destinatário GPG definido (.gpg-id ausente ou vazio)"
	[erro_encrypt]="falha ao criptografar para '%s': %s"
	[erro_mv_cifrado]="falha ao mover arquivo cifrado para '%s'"
	[erro_sem_gpgid]="identidade sem .gpg-id: %s"
	[erro_gpgid_vazio]="%s está vazio"

	[erro_id_nao_encontrada]="identidade não encontrada: %s"
	[erro_id_sem_gpgid]="'%s' não é uma identidade (sem .gpg-id)"
	[erro_informe_destinatario]="informe ao menos um destinatário GPG"
	[erro_id_ja_existe]="identidade já existe: %s"
	[erro_falha_criar_id]="falha ao criar identidade: %s"
	[msg_id_criada]="Identidade \"%s\" criada para: %s\n"
	[erro_mapa_corrompido]="mapa corrompido ou de versão desconhecida em %s"
	[erro_lock_abrir]="falha ao abrir lock: %s"
	[erro_lock_obter]="falha ao obter lock: %s"
	[erro_entrada_existe]="já existe uma entrada em '%s'"
	[erro_nao_encontrado]="'%s' não encontrado"

	[erro_logico_nao_encontrado]="%s: %s não encontrado"
	[erro_opcao_desconhecida]="opção desconhecida: %s"
	[prompt_sobrescrever]="Sobrescrever %s: %s? [y/N] "
	[msg_cancelado]="Cancelado.\n"
	[erro_senhas_diferentes]="as senhas não coincidem"
	[msg_salvo]="%s: %s salvo.\n"
	[prompt_remover]="Remover %s: %s? [y/N] "
	[msg_removido]="%s: %s removido.\n"
	[erro_dest_ja_existe]="%s: %s já existe"
	[erro_comprimento_invalido]="comprimento inválido: %s"
	[prompt_sobrescrever_existe]="%s: %s já existe. Sobrescrever? [y/N] "
	[erro_entropia]="falha ao gerar senha (entropia insuficiente lida de /dev/urandom)"
	[erro_editor]="editor saiu com erro, nada foi salvo"
	[msg_atualizado]="%s: %s atualizado.\n"
	[msg_sem_alteracoes]="Sem alterações.\n"

	[erro_wlcopy]="wl-copy não encontrado (wl-clipboard). npass é Wayland-only."
	[erro_sem_wayland]="sem sessão Wayland ativa (\$WAYLAND_DISPLAY vazio)."
	[msg_copiado]="Copiado (%s). Limpa em %ss ou no primeiro paste.\n"

	[erro_otp_parse]="não foi possível interpretar a URI OTP"
	[erro_otp_sem_conta]="URI OTP inválida (sem accountname)"
	[erro_otp_sem_secret]="URI OTP inválida (sem secret)"
	[erro_otp_sem_counter]="URI OTP inválida (hotp sem counter)"
	[erro_uris_diferentes]="as URIs não coincidem"
	[erro_secrets_diferentes]="os secrets não coincidem"
	[erro_sem_gerador_otp]="nenhum gerador de OTP disponível (instale oathtool ou otptool)"
	[erro_oathtool_antigo]="oathtool %s é antigo demais para ler o secret via stdin com segurança (mínimo %s); npass não expõe o secret na linha de comando. Atualize o oathtool ou instale otptool."
	[erro_gerar_otp]="falha ao gerar código OTP"
	[erro_sem_otp]="%s: %s não tem segredo OTP"
	[erro_hotp_sem_counter]="%s: %s: URI HOTP sem parâmetro counter"
	[erro_qrencode]="qrencode não encontrado"
	[prompt_otp_sobrescrever]="%s: %s já tem um segredo OTP. Sobrescrever? [y/N] "
	[erro_issuer_ou_account]="informe --issuer ou --account"
	[msg_otp_salvo]="%s: %s (OTP) salvo.\n"

	[warn_pattern_nao_encontrado]="%s não encontrado, ignorando."
	[erro_provide_multiline]="--provide e --multiline são mutuamente exclusivos"
	[erro_informe_id_pattern]="informe ID e ao menos um PATTERN"
	[erro_nenhuma_entrada]="nenhuma entrada correspondente em %s"
	[warn_falha_decifrar]="%s: falha ao decifrar, pulando"
	[prompt_pronto]="Pronto para %s uma nova senha? [y/N] "
	[verbo_gerar]="gerar"
	[verbo_fornecer]="fornecer"

	[erro_dir_nao_encontrado]="diretório não encontrado: %s"
	[erro_informe_id_dir]="informe ID e DIRETÓRIO_ANTIGO"
	[erro_id_sem_auto_criar]="identidade '%s' não existe e %s não tem .gpg-id para criá-la automaticamente"
	[warn_migrate_existe]="%s já existe em %s, pulando (use -f para sobrescrever)"
	[msg_migrate_resumo]="Migração para \"%s\" concluída: %d importado(s), %d pulado(s), %d falhou(aram).\n"

	[erro_comando_desconhecido]="comando desconhecido: %s (veja 'npass help')"
	[rotulo_aviso]="aviso"
	[erro_gpg_desconhecido]="erro desconhecido do gpg"
	[prompt_senha_para]="Senha para %s: %s: "
	[prompt_repita_senha]="Repita a senha: "
	[prompt_uri_otp]="URI otpauth:// para %s: "
	[prompt_repita_uri]="Repita a URI: "
	[prompt_secret_totp]="Secret TOTP para %s: "
	[prompt_repita_secret]="Repita o secret: "
	[prompt_nova_senha]="Nova senha para %s: %s: "
	[prompt_repita]="Repita: "
	[msg_digite_conteudo]="Digite o novo conteúdo de %s e pressione Ctrl+D quando terminar:\n"
	[msg_usando_comprimento]="Usando o comprimento da senha antiga: %s\n"
	[msg_nenhum_arquivo_gpg]="Nenhum arquivo .gpg encontrado em %s.\n"
	[erro_assinar_gpgid]="falha ao assinar .gpg-id em %s: %s"
	[erro_assinatura_invalida]="assinatura de .gpg-id inválida em %s - possível adulteração do destinatário GPG: %s"
	[msg_assinado]="Identidade \"%s\" assinada.\n"
	[warn_secrets_sem_decifrar]=".secrets.gpg falhou ao decifrar - importando sem nomes reais"
	[warn_mask_sem_decifrar]=".mask.gpg falhou ao decifrar - importando sem aliases de email"
)

declare -gA NPASS_MSG_EN=(
	[erro_caminho_invalido]="invalid path: '%s'"
	[erro_caminho_tab]="invalid path (contains tab/newline): '%s'"
	[erro_tmp_dir]="could not create secure temp directory"
	[erro_arquivo_nao_encontrado]="file not found: %s"
	[erro_decrypt]="failed to decrypt '%s': %s"
	[erro_sem_destinatarios]="no GPG recipient set (.gpg-id missing or empty)"
	[erro_encrypt]="failed to encrypt to '%s': %s"
	[erro_mv_cifrado]="failed to move encrypted file to '%s'"
	[erro_sem_gpgid]="identity has no .gpg-id: %s"
	[erro_gpgid_vazio]="%s is empty"

	[erro_id_nao_encontrada]="identity not found: %s"
	[erro_id_sem_gpgid]="'%s' is not an identity (no .gpg-id)"
	[erro_informe_destinatario]="provide at least one GPG recipient"
	[erro_id_ja_existe]="identity already exists: %s"
	[erro_falha_criar_id]="failed to create identity: %s"
	[msg_id_criada]="Identity \"%s\" created for: %s\n"
	[erro_mapa_corrompido]="corrupted or unknown-version map in %s"
	[erro_lock_abrir]="failed to open lock: %s"
	[erro_lock_obter]="failed to acquire lock: %s"
	[erro_entrada_existe]="an entry already exists at '%s'"
	[erro_nao_encontrado]="'%s' not found"

	[erro_logico_nao_encontrado]="%s: %s not found"
	[erro_opcao_desconhecida]="unknown option: %s"
	[prompt_sobrescrever]="Overwrite %s: %s? [y/N] "
	[msg_cancelado]="Cancelled.\n"
	[erro_senhas_diferentes]="passwords do not match"
	[msg_salvo]="%s: %s saved.\n"
	[prompt_remover]="Remove %s: %s? [y/N] "
	[msg_removido]="%s: %s removed.\n"
	[erro_dest_ja_existe]="%s: %s already exists"
	[erro_comprimento_invalido]="invalid length: %s"
	[prompt_sobrescrever_existe]="%s: %s already exists. Overwrite? [y/N] "
	[erro_entropia]="failed to generate password (insufficient entropy read from /dev/urandom)"
	[erro_editor]="editor exited with an error, nothing was saved"
	[msg_atualizado]="%s: %s updated.\n"
	[msg_sem_alteracoes]="No changes.\n"

	[erro_wlcopy]="wl-copy not found (wl-clipboard). npass is Wayland-only."
	[erro_sem_wayland]="no active Wayland session (\$WAYLAND_DISPLAY empty)."
	[msg_copiado]="Copied (%s). Clears in %ss or on first paste.\n"

	[erro_otp_parse]="could not parse the OTP URI"
	[erro_otp_sem_conta]="invalid OTP URI (no accountname)"
	[erro_otp_sem_secret]="invalid OTP URI (no secret)"
	[erro_otp_sem_counter]="invalid OTP URI (hotp with no counter)"
	[erro_uris_diferentes]="the URIs do not match"
	[erro_secrets_diferentes]="the secrets do not match"
	[erro_sem_gerador_otp]="no OTP generator available (install oathtool or otptool)"
	[erro_oathtool_antigo]="oathtool %s is too old to safely read the secret via stdin (minimum %s); npass never exposes the secret on the command line. Upgrade oathtool or install otptool."
	[erro_gerar_otp]="failed to generate OTP code"
	[erro_sem_otp]="%s: %s has no OTP secret"
	[erro_hotp_sem_counter]="%s: %s: HOTP URI has no counter parameter"
	[erro_qrencode]="qrencode not found"
	[prompt_otp_sobrescrever]="%s: %s already has an OTP secret. Overwrite? [y/N] "
	[erro_issuer_ou_account]="provide --issuer or --account"
	[msg_otp_salvo]="%s: %s (OTP) saved.\n"

	[warn_pattern_nao_encontrado]="%s not found, skipping."
	[erro_provide_multiline]="--provide and --multiline are mutually exclusive"
	[erro_informe_id_pattern]="provide ID and at least one PATTERN"
	[erro_nenhuma_entrada]="no matching entry in %s"
	[warn_falha_decifrar]="%s: failed to decrypt, skipping"
	[prompt_pronto]="Ready to %s a new password? [y/N] "
	[verbo_gerar]="generate"
	[verbo_fornecer]="provide"

	[erro_dir_nao_encontrado]="directory not found: %s"
	[erro_informe_id_dir]="provide ID and OLD_DIRECTORY"
	[erro_id_sem_auto_criar]="identity '%s' does not exist and %s has no .gpg-id to auto-create it"
	[warn_migrate_existe]="%s already exists in %s, skipping (use -f to overwrite)"
	[msg_migrate_resumo]="Migration to \"%s\" complete: %d imported, %d skipped, %d failed.\n"

	[erro_comando_desconhecido]="unknown command: %s (see 'npass help')"
	[rotulo_aviso]="warning"
	[erro_gpg_desconhecido]="unknown gpg error"
	[prompt_senha_para]="Password for %s: %s: "
	[prompt_repita_senha]="Repeat password: "
	[prompt_uri_otp]="otpauth:// URI for %s: "
	[prompt_repita_uri]="Repeat the URI: "
	[prompt_secret_totp]="TOTP secret for %s: "
	[prompt_repita_secret]="Repeat the secret: "
	[prompt_nova_senha]="New password for %s: %s: "
	[prompt_repita]="Repeat: "
	[msg_digite_conteudo]="Type the new content for %s and press Ctrl+D when done:\n"
	[msg_usando_comprimento]="Using the old password's length: %s\n"
	[msg_nenhum_arquivo_gpg]="No .gpg files found in %s.\n"
	[erro_assinar_gpgid]="failed to sign .gpg-id in %s: %s"
	[erro_assinatura_invalida]="invalid .gpg-id signature in %s - possible tampering with the GPG recipient: %s"
	[msg_assinado]="Identity \"%s\" signed.\n"
	[warn_secrets_sem_decifrar]=".secrets.gpg failed to decrypt - importing without real names"
	[warn_mask_sem_decifrar]=".mask.gpg failed to decrypt - importing without email aliases"
)

# npass_t KEY [ARGS...]
# Looks up KEY in the active language table (NPASS_LANG starting with
# "en" -> English; anything else, including unset, -> Portuguese, which
# is the tool's default/core language) and printf-expands it with ARGS.
# Falls back to Portuguese, then to the bare key, if a translation is
# missing - npass never dies because a message table has a gap.
npass_t() {
	local key="$1"; shift
	local fmt
	if [[ "$NPASS_LANG" == en* && -n "${NPASS_MSG_EN[$key]+_}" ]]; then
		fmt="${NPASS_MSG_EN[$key]}"
	else
		fmt="${NPASS_MSG_PT[$key]:-$key}"
	fi
	# shellcheck disable=SC2059
	# $fmt is intentionally the format string: this function's entire
	# job is printf-format lookup. It only ever comes from our own
	# hardcoded NPASS_MSG_PT/EN tables above, never from user input,
	# so there's no format-string injection here despite the variable
	# format.
	printf -- "$fmt" "$@"
}
