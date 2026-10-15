#!/usr/bin/env bash
# npass - formato md1: o conteudo (decifrado) de TODA entrada.
#
# E o unico parser/renderizador do formato. Nenhum outro modulo interpreta o
# texto de uma entrada por conta propria: clip, get, otp, pin, update,
# generate, diceware, edit, import e as extensoes passam por aqui.
#
#   <!-- npass:md1 -->
#   ## Senha
#   valor-cru-sem-trim
#
#   ## Campos
#   - login: fulano
#   - url: https://exemplo
#
#   ## OTP
#   otpauth://totp/...
#
#   ## Notas
#   texto livre; sempre a ultima secao
#
# Regras:
#   - a 1a linha e exatamente o marcador; sem ele a entrada nao esta em md1
#   - "## Senha" e obrigatoria e vem primeiro; a SENHA e a linha logo abaixo
#     do cabecalho, lida por posicao e sem tirar espacos (por isso uma senha
#     pode comecar com "#", "-", "## " ou ter espacos nas pontas)
#   - Campos, OTP e Notas sao opcionais, nessa ordem, no maximo uma vez cada
#   - Notas vai ate o fim: qualquer linha depois de "## Notas" e nota, mesmo
#     que pareca cabecalho ou campo
#   - uma linha de campo e "- chave: valor"; chave = texto entre "- " e o 1o
#     ":", sem espacos nas pontas, sem diferenciar maiusculas
#   - linha nao reconhecida dentro de Campos/OTP e mantida como esta (nada
#     some ao reescrever); fora de secao, ou apos a senha, e formato invalido
#
# O estado fica em globais (NPASS_E_*): chame npass_entry_load / _require
# DIRETO, nunca dentro de $(...), senao o estado se perde no subshell.

NPASS_ENTRY_MARKER='<!-- npass:md1 -->'

NPASS_E_PW=""
NPASS_E_FIELDS=()
NPASS_E_OTP=()
NPASS_E_NOTES=""

npass_entry_reset() {
	NPASS_E_PW="${1-}"
	NPASS_E_FIELDS=()
	NPASS_E_OTP=()
	NPASS_E_NOTES=""
}

# npass_entry_is_v2 CONTEUDO -> 0 se a 1a linha e o marcador md1.
npass_entry_is_v2() {
	[[ "${1%%$'\n'*}" == "$NPASS_ENTRY_MARKER" ]]
}

# npass_entry_load CONTEUDO -> preenche NPASS_E_*.
# Retorna 0 ok, 1 se nao esta em md1 (formato antigo ou lixo), 2 se tem o
# marcador mas a estrutura e invalida.
npass_entry_load() {
	local content="$1" line state="" rank=0 n=0 notes_started=0
	npass_entry_reset
	npass_entry_is_v2 "$content" || return 1
	while IFS= read -r line; do
		((n++))
		((n == 1)) && continue
		if [[ "$state" == notes ]]; then
			if ((notes_started)); then
				NPASS_E_NOTES+=$'\n'"$line"
			else
				NPASS_E_NOTES="$line"
				notes_started=1
			fi
			continue
		fi
		if [[ "$state" == pw ]]; then
			NPASS_E_PW="$line"
			state=pwdone
			continue
		fi
		case "$line" in
		'## Senha') ((rank < 1)) || return 2; rank=1; state=pw ;;
		'## Campos') ((rank >= 1 && rank < 2)) || return 2; rank=2; state=fields ;;
		'## OTP') ((rank >= 1 && rank < 3)) || return 2; rank=3; state=otp ;;
		'## Notas') ((rank >= 1 && rank < 4)) || return 2; rank=4; state=notes ;;
		*)
			[[ -z "${line//[[:space:]]/}" ]] && continue
			case "$state" in
			fields) NPASS_E_FIELDS+=("$line") ;;
			otp) NPASS_E_OTP+=("$line") ;;
			*) return 2 ;;
			esac
			;;
		esac
	done <<<"$content"
	((rank >= 1)) || return 2
	return 0
}

# npass_entry_render -> o documento md1 do estado atual (sem \n final).
npass_entry_render() {
	local out="$NPASS_ENTRY_MARKER"$'\n'"## Senha"$'\n'"$NPASS_E_PW" l
	if ((${#NPASS_E_FIELDS[@]})); then
		out+=$'\n\n## Campos'
		for l in "${NPASS_E_FIELDS[@]}"; do out+=$'\n'"$l"; done
	fi
	if ((${#NPASS_E_OTP[@]})); then
		out+=$'\n\n## OTP'
		for l in "${NPASS_E_OTP[@]}"; do out+=$'\n'"$l"; done
	fi
	[[ -n "$NPASS_E_NOTES" ]] && out+=$'\n\n## Notas\n'"$NPASS_E_NOTES"
	printf '%s' "$out"
}

# npass_entry_new SENHA -> documento md1 de uma entrada nova so com a senha.
npass_entry_new() {
	npass_entry_reset "$1"
	npass_entry_render
}

# npass_entry_with_password CONTEUDO SENHA -> o mesmo documento com outra senha.
# Campos, OTP e notas passam intactos. Falha (1/2) se CONTEUDO nao for md1.
npass_entry_with_password() {
	npass_entry_load "$1" || return $?
	NPASS_E_PW="$2"
	npass_entry_render
}

# npass_entry_require ID LOGICAL CONTEUDO -> carrega ou morre com a mensagem
# certa (formato antigo / anexo de backup / estrutura invalida).
npass_entry_require() {
	local id="$1" logical="$2" rc=0
	npass_entry_load "$3" || rc=$?
	((rc == 0)) && return 0
	if ((rc == 1)); then
		if npass_backup_is_marker "$3"; then
			npass_die "$(npass_t erro_entrada_anexo "$id" "$logical")"
		fi
		npass_die "$(npass_t erro_formato_antigo "$id" "$logical" "$id")"
	fi
	npass_die "$(npass_t erro_formato_invalido "$id" "$logical")"
}

# --- campos ----------------------------------------------------------------

# npass_entry_field_key LINHA -> chave (minuscula) em $REPLY; 1 se nao e campo.
npass_entry_field_key() {
	local re='^-[[:space:]]+([^:]+):' k
	[[ "$1" =~ $re ]] || return 1
	k="${BASH_REMATCH[1]}"
	k="${k#"${k%%[![:space:]]*}"}"
	k="${k%"${k##*[![:space:]]}"}"
	[[ -n "$k" ]] || return 1
	REPLY="${k,,}"
}

# npass_entry_field_value LINHA -> valor em $REPLY.
npass_entry_field_value() {
	local re='^-[[:space:]]+[^:]+:[[:space:]]*(.*)$'
	[[ "$1" =~ $re ]] || return 1
	REPLY="${BASH_REMATCH[1]}"
}

# npass_entry_field_has CHAVE -> 0 se ha um campo com exatamente essa chave.
npass_entry_field_has() {
	local want="${1,,}" l
	for l in "${NPASS_E_FIELDS[@]}"; do
		npass_entry_field_key "$l" && [[ "$REPLY" == "$want" ]] && return 0
	done
	return 1
}

# npass_entry_field_set CHAVE VALOR -> troca o PRIMEIRO campo com essa chave
# (a que `npass clip CHAVE` le) ou acrescenta no fim do bloco de campos.
npass_entry_field_set() {
	local want="${1,,}" value="$2" i
	for i in "${!NPASS_E_FIELDS[@]}"; do
		if npass_entry_field_key "${NPASS_E_FIELDS[i]}" && [[ "$REPLY" == "$want" ]]; then
			NPASS_E_FIELDS[i]="- $1: $value"
			return 0
		fi
	done
	NPASS_E_FIELDS+=("- $1: $value")
}

# --- OTP -------------------------------------------------------------------

# npass_entry_otp_uri -> a 1a linha otpauth:// da secao OTP; 1 se nao ha.
npass_entry_otp_uri() {
	local l
	for l in "${NPASS_E_OTP[@]}"; do
		[[ "$l" == otpauth://* ]] && { printf '%s\n' "$l"; return 0; }
	done
	return 1
}

# npass_entry_otp_set URI -> troca a 1a linha otpauth:// ou acrescenta.
npass_entry_otp_set() {
	local i
	for i in "${!NPASS_E_OTP[@]}"; do
		if [[ "${NPASS_E_OTP[i]}" == otpauth://* ]]; then
			NPASS_E_OTP[i]="$1"
			return 0
		fi
	done
	NPASS_E_OTP+=("$1")
}
