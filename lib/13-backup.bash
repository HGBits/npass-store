#!/usr/bin/env bash
# npass - senhas de backup (codigos de recuperacao) guardadas num arquivo
# cifrado ANEXO a uma entrada.
#
# npass backup [-f] -n N ID DIR/PASS pede N senhas (ocultas, com confirmacao)
# e grava dois blobs na mesma identidade, ambos cifrados para o .gpg-id:
#
#   DIR/PASS/Backup-<svc>.md         ponteiro (sem segredo): nome do arquivo
#                                    de dados, quantidade e data
#   DIR/PASS/Backup-<svc>.dados.md   as N senhas, uma por secao "## Backup i"
#
# <svc> e o ultimo componente de DIR/PASS. O mapa e plano (logico -> blob),
# entao "DIR/PASS" e "DIR/PASS/Backup-..." convivem sem conflito.
#
# Um anexo so e reconhecido como tal quando o NOME bate (Backup-*.md, filho
# direto da entrada) E a 1a linha decifrada e o marcador abaixo. Nome sozinho
# nao basta: uma entrada do usuario chamada "Backup-x.md" nao pode ser
# arrastada por rm/mv nem pulada pelo update.

NPASS_BACKUP_MIN=1
NPASS_BACKUP_MAX=50
NPASS_BACKUP_MARKER_RE='^<!-- npass:backup-(index|data) v1 -->$'

# npass_backup_is_marker CONTEUDO -> 0 se a 1a linha e marcador de anexo.
npass_backup_is_marker() {
	local first="${1%%$'\n'*}"
	[[ "$first" =~ $NPASS_BACKUP_MARKER_RE ]]
}

# npass_backup_is_attachment ID LOGICAL -> 0 se LOGICAL e um anexo de backup.
# O teste barato (nome) vem antes; so decifra quando o nome combina.
npass_backup_is_attachment() {
	local id="$1" logical="$2"
	[[ "${logical##*/}" == Backup-*.md ]] || return 1
	local content
	content="$(cmd_show "$id" "$logical" 2>/dev/null)" || return 1
	npass_backup_is_marker "$content"
}

# npass_backup_attachments ID DIR LOGICAL
# Imprime (um por linha) os caminhos logicos dos anexos de LOGICAL. Falha se
# algum candidato nao puder ser decifrado: quem remove/move precisa saber que
# nao enxergou tudo, em vez de deixar anexo orfao em silencio.
npass_backup_attachments() {
	local id="$1" dir="$2" logical="$3" l rest content
	while IFS= read -r l; do
		[[ "$l" == "$logical"/Backup-*.md ]] || continue
		rest="${l#"$logical"/}"
		[[ "$rest" == */* ]] && continue
		content="$(cmd_show "$id" "$l")" || return 1
		npass_backup_is_marker "$content" && printf '%s\n' "$l"
	done < <(npass_map_list "$dir")
	return 0
}

# npass_backup_drop DIR LOGICAL: tira do mapa e destroi o blob (shred).
npass_backup_drop() {
	local dir="$1" logical="$2" physical blob
	physical="$(npass_map_delete "$dir" "$logical")"
	[[ -z "$physical" ]] && return 0
	blob="$(npass_blob_path "$dir" "$physical")"
	if [[ -f "$blob" ]]; then
		shred -u -- "$blob" 2>/dev/null || rm -f -- "$blob"
	fi
	return 0
}

cmd_backup_usage() {
	printf '%s\n' "uso: npass backup [-f] -n N ID DIR/PASS" \
		"  grava N senhas de backup (interativo, ocultas) num arquivo cifrado" \
		"  anexo a DIR/PASS: DIR/PASS/Backup-<svc>.md (ponteiro) e" \
		"  DIR/PASS/Backup-<svc>.dados.md (as senhas). A entrada precisa existir." \
		"  -n N   quantidade de senhas, de ${NPASS_BACKUP_MIN} a ${NPASS_BACKUP_MAX}" \
		"  -f     substitui um backup existente sem perguntar"
}

cmd_backup() {
	local force=0 n=""
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		-n | --number) n="${2-}"; shift; (($#)) && shift ;;
		-h | --help) cmd_backup_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass backup [-f] -n N ID DIR/PASS"
	if [[ ! "$n" =~ ^[0-9]+$ ]] || ((10#$n < NPASS_BACKUP_MIN || 10#$n > NPASS_BACKUP_MAX)); then
		npass_die "$(npass_t erro_backup_n_invalido "$n" "$NPASS_BACKUP_MIN" "$NPASS_BACKUP_MAX")"
	fi
	n=$((10#$n))
	npass_check_sneaky_path "$logical"

	local dir physical
	dir="$(npass_identity_dir "$id")"
	physical="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)" && [[ -n "$physical" ]] \
		|| npass_die "$(npass_t erro_backup_sem_entrada "$id" "$logical")"
	npass_backup_is_attachment "$id" "$logical" \
		&& npass_die "$(npass_t erro_backup_em_anexo "$id" "$logical")"

	local svc="${logical##*/}"
	local ptr="$logical/Backup-$svc.md" dat="$logical/Backup-$svc.dados.md"

	# Backup anterior: descoberto pelo diretorio (nao pelo nome derivado), porque
	# um mv que renomeia a entrada mantem o nome antigo dos anexos. Os nomes
	# derivados so podem ja existir se forem anexos de verdade.
	local atts_out o name dat_old=0 exists=0
	local -a old=()
	atts_out="$(npass_backup_attachments "$id" "$dir" "$logical")" \
		|| npass_die "$(npass_t erro_backup_ler_anexos "$id" "$logical")"
	[[ -n "$atts_out" ]] && mapfile -t old <<<"$atts_out"
	((${#old[@]})) && exists=1
	for name in "$ptr" "$dat"; do
		[[ -n "$(npass_map_resolve "$dir" "$name" 2>/dev/null)" ]] || continue
		local mine=0
		for o in "${old[@]}"; do [[ "$o" == "$name" ]] && mine=1; done
		((mine)) || npass_die "$(npass_t erro_backup_nome_ocupado "$id" "$name")"
	done
	for o in "${old[@]}"; do [[ "$o" == "$dat" ]] && dat_old=1; done
	if [[ $exists -eq 1 && $force -eq 0 ]]; then
		local reply
		read -r -p "$(npass_t prompt_backup_existe "$id" "$logical")" reply
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi

	# Coleta tudo antes de gravar: nada vai ao disco se alguma entrada falhar.
	local -a pws=()
	local i j p1 p2
	for ((i = 1; i <= n; i++)); do
		IFS= read -r -s -p "$(npass_t prompt_backup_senha "$id" "$logical" "$i" "$n")" p1 || exit 1
		echo
		[[ -n "$p1" ]] || npass_die "$(npass_t erro_backup_vazia "$i")"
		IFS= read -r -s -p "$(npass_t prompt_repita_senha)" p2 || exit 1
		echo
		[[ "$p1" == "$p2" ]] || npass_die "$(npass_t erro_senhas_diferentes)"
		for ((j = 0; j < ${#pws[@]}; j++)); do
			[[ "${pws[j]}" == "$p1" ]] \
				&& npass_die "$(npass_t erro_backup_repetida "$i" "$((j + 1))")"
		done
		pws+=("$p1")
	done

	local data pointer
	data="<!-- npass:backup-data v1 -->"$'\n'"# Senhas de backup: $svc"$'\n'
	for ((i = 0; i < n; i++)); do
		data+=$'\n'"## Backup $((i + 1))"$'\n'"${pws[i]}"$'\n'
	done
	data="${data%$'\n'}"
	pointer="<!-- npass:backup-index v1 -->"$'\n'"# Backup-$svc"$'\n\n'
	pointer+="- arquivo: Backup-$svc.dados.md"$'\n'
	pointer+="- quantidade: $n"$'\n'
	pointer+="- criado: $(date +%F)"

	# Dados primeiro, ponteiro depois. Se o ponteiro falhar num backup novo,
	# desfaz os dados para nao deixar um blob cifrado sem ninguem apontando.
	npass_blob_write "$dir" "$dat" "$data"
	if ! (npass_blob_write "$dir" "$ptr" "$pointer"); then
		((dat_old)) || npass_backup_drop "$dir" "$dat"
		npass_die "$(npass_t erro_backup_gravar "$id" "$logical")"
	fi
	unset pws data
	# anexos antigos com outro nome (entrada renomeada) sao substituidos
	for o in "${old[@]}"; do
		[[ "$o" == "$ptr" || "$o" == "$dat" ]] || npass_backup_drop "$dir" "$o"
	done
	npass_git_commit "$id" "backup"
	npass_t msg_backup_salvo "$id" "$logical" "$n" "$dat"
}
