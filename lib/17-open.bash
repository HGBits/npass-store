#!/usr/bin/env bash
# npass open npass://ID/caminho/logico - segue um link npass://.
#
# O `show` renderizado (16-view) desenha links npass:// para navegar entre uma
# entrada e os seus backups. O glow os emite como hiperlink OSC 8; clicar num
# terminal que suporte OSC 8 entrega a URL ao handler do desktop
# (x-scheme-handler/npass, packaging/npass-open.desktop), que roda este comando.
#
#   npass open URL           em terminal: mostra a entrada aqui
#                            fora de terminal (chamado pelo desktop): abre uma
#                            janela de terminal que roda `npass open --here --pause URL`
#   npass open --here URL    sempre aqui
#   --pause                  espera Enter (ou NPASS_OPEN_TIMEOUT s, padrao 60) e
#                            limpa a tela, para o segredo nao ficar no scrollback
#
# SEGURANCA. Quem aciona este comando e, na pratica, qualquer coisa que consiga
# entregar uma URL npass:// ao desktop: uma pagina web, uma nota importada, um
# link num e-mail. Por isso:
#   - so MOSTRA: nunca copia, grava, apaga nem muda nada;
#   - pede confirmacao (y/N) mostrando ID e caminho ANTES de decifrar qualquer
#     coisa, a menos que NPASS_OPEN_CONFIRM=0 (so p/ quem entende o risco);
#   - o parser e estrito: so o esquema npass://, ID simples, caminho que passa
#     por npass_check_sneaky_path, e recusa %-escape invalido, NUL e controle.

# npass_url_encode TEXTO -> TEXTO como caminho de URL: so A-Za-z0-9 . _ ~ - /
# ficam como estao; o resto (inclusive bytes de UTF-8, espaco, # ? % \) vira %XX.
npass_url_encode() {
	local LC_ALL=C s="$1" out="" c h i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		[A-Za-z0-9._~/-]) out+="$c" ;;
		*)
			printf -v h '%%%02X' "'$c"
			out+="$h"
			;;
		esac
	done
	printf '%s' "$out"
}

# npass_url_decode TEXTO -> bytes originais em stdout. 1 se o %-escape for invalido
# (% sem dois digitos hex) ou se decodificar para NUL.
npass_url_decode() {
	local LC_ALL=C s="$1"
	local bad='%($|[^0-9A-Fa-f]|[0-9A-Fa-f]($|[^0-9A-Fa-f]))'
	[[ "$s" =~ $bad ]] && return 1
	[[ "$s" == *%00* ]] && return 1
	s="${s//\\/\\\\}"
	printf '%b' "${s//%/\\x}"
}

# npass_open_parse URL -> NPASS_OPEN_ID e NPASS_OPEN_LOGICAL, ou 1.
npass_open_parse() {
	local url="$1" rest id path
	[[ "$url" == npass://* ]] || return 1
	rest="${url#npass://}"
	rest="${rest%%[?#]*}"
	[[ "$rest" == */* ]] || return 1
	id="${rest%%/*}"
	path="${rest#*/}"
	[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	[[ -n "$path" && "$path" != */ ]] || return 1
	path="$(npass_url_decode "$path")" || return 1
	[[ -n "$path" && "$path" != *[[:cntrl:]]* ]] || return 1
	(npass_check_sneaky_path "$path") >/dev/null 2>&1 || return 1
	NPASS_OPEN_ID="$id"
	NPASS_OPEN_LOGICAL="$path"
}

# npass_open_terminal -> NPASS_OPEN_TERM (array): o prefixo que roda um comando
# numa janela de terminal. NPASS_TERMINAL manda (dividido em palavras), depois
# $TERMINAL (com -e), depois o primeiro que existir de foot, kitty, alacritty,
# wezterm, xterm.
npass_open_terminal() {
	NPASS_OPEN_TERM=()
	if [[ -n "${NPASS_TERMINAL:-}" ]]; then
		read -r -a NPASS_OPEN_TERM <<<"$NPASS_TERMINAL"
		return 0
	fi
	if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null 2>&1; then
		NPASS_OPEN_TERM=("$TERMINAL" -e)
		return 0
	fi
	local cand
	for cand in foot kitty "alacritty -e" "wezterm start --" "xterm -e"; do
		if command -v "${cand%% *}" >/dev/null 2>&1; then
			read -r -a NPASS_OPEN_TERM <<<"$cand"
			return 0
		fi
	done
	return 1
}

cmd_open_usage() {
	printf '%s\n' "uso: npass open [--here] [--pause] npass://ID/DIR/PASS" \
		"  mostra uma entrada (so mostra) a partir de um link npass://" \
		"  --here    mostra neste terminal, mesmo sem tty" \
		"  --pause   espera Enter e limpa a tela ao final" \
		"  NPASS_OPEN_CONFIRM=0 pula a confirmacao; NPASS_TERMINAL escolhe o terminal"
}

cmd_open() {
	local here=0 pause=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		--here) here=1; shift ;;
		--pause) pause=1; shift ;;
		-h | --help) cmd_open_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local url="$1"
	[[ -n "$url" ]] || npass_die "uso: npass open [--here] [--pause] npass://ID/DIR/PASS"
	npass_open_parse "$url" || npass_die "$(npass_t erro_open_url)"

	# Chamado pelo desktop (sem terminal): abre uma janela de terminal que roda
	# este mesmo comando; a confirmacao e a exibicao acontecem la.
	if ((!here)) && [[ ! -t 1 ]]; then
		npass_open_terminal || npass_die "$(npass_t erro_open_sem_terminal)"
		local self
		self="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
		if command -v setsid >/dev/null 2>&1; then
			setsid -f "${NPASS_OPEN_TERM[@]}" "$self" open --here --pause "$url" >/dev/null 2>&1 </dev/null
		else
			"${NPASS_OPEN_TERM[@]}" "$self" open --here --pause "$url" >/dev/null 2>&1 </dev/null &
		fi
		return 0
	fi

	if [[ "${NPASS_OPEN_CONFIRM:-1}" != 0 ]]; then
		local reply=""
		read -r -p "$(npass_t prompt_open_confirma "$NPASS_OPEN_ID" "$NPASS_OPEN_LOGICAL")" reply || true
		[[ "$reply" == [yY] ]] || { npass_t msg_cancelado; return 1; }
	fi

	local rc=0
	cmd_view "$NPASS_OPEN_ID" "$NPASS_OPEN_LOGICAL" || rc=$?
	if ((pause)); then
		local _
		read -r -s -t "${NPASS_OPEN_TIMEOUT:-60}" -p "$(npass_t prompt_open_pausa)" _ || true
		echo
		[[ -t 1 ]] && printf '\033[2J\033[3J\033[H'
	fi
	return "$rc"
}
