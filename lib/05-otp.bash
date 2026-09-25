#!/usr/bin/env bash
# npass - OTP (pass-otp equivalent), ported onto identity resolution.
#
# Hard security rule, non-negotiable: the raw OTP secret NEVER appears
# as a command-line argument to any external process. Upstream pass-otp
# has a fallback path that does exactly that when oathtool is "too old",
# and the version check guarding that fallback used `sort -n` on a
# dotted version string - which misorders as soon as any component
# reaches two digits (2.6.5 vs 2.6.11: sort -n puts 2.6.11 first). We
# tested this: it makes pass-otp take the unsafe argv path on ANY
# oathtool 2.6.10+, even though those versions support reading the
# secret from stdin. We do not carry that fallback at all: if neither
# otptool nor a stdin-capable oathtool is available, npass refuses.

readonly NPASS_OATH_MIN_STDIN_VERSION="2.6.5"
OATH="$(command -v oathtool || true)"
OTPTOOL="$(command -v otptool || true)"

# Robust dotted-version compare, replacing the sort -n bug outright.
# Returns 0 (true) if $1 >= $2.
npass_version_ge() {
	local a="$1" b="$2"
	local -a av bv
	IFS=. read -r -a av <<<"$a"
	IFS=. read -r -a bv <<<"$b"
	local i n=${#av[@]}
	[[ ${#bv[@]} -gt $n ]] && n=${#bv[@]}
	for ((i = 0; i < n; i++)); do
		local x="${av[i]:-0}" y="${bv[i]:-0}"
		x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
		x="${x:-0}"; y="${y:-0}"
		((10#$x > 10#$y)) && return 0
		((10#$x < 10#$y)) && return 1
	done
	return 0
}

# source: https://gist.github.com/cdown/1163649
npass_urlencode() {
	local s="$1" l=${#1} i c
	for ((i = 0; i < l; i++)); do
		c="${s:i:1}"
		case "$c" in
		[a-zA-Z0-9.~_-]) printf '%c' "$c" ;;
		' ') printf + ;;
		*) printf '%%%.2X' "'$c" ;;
		esac
	done
}

npass_urldecode() {
	local enc="${1//+/ }"
	printf '%b' "${enc//%/\\x}"
}

# Parse an otpauth:// URI. Sets otp_type, otp_label, otp_accountname,
# otp_issuer, otp_secret, otp_digits, otp_algorithm, otp_period,
# otp_counter, otp_uri. Consumed by the caller as globals, same
# contract as upstream pass-otp.
# shellcheck disable=SC2034
otp_parse_uri() {
	local uri="$1"
	uri="${uri//\`/%60}"
	uri="${uri//\"/%22}"

	local pattern='^otpauth:\/\/(totp|hotp)(\/(([^:?]+)?(:([^:?]*))?)(:([0-9]+))?)?\?(.+)$'
	[[ "$uri" =~ $pattern ]] || npass_die "não foi possível interpretar a URI OTP"

	otp_uri="${BASH_REMATCH[0]}"
	otp_type="${BASH_REMATCH[1]}"
	otp_label="${BASH_REMATCH[3]}"
	otp_secret="" otp_digits="" otp_algorithm="" otp_period="" otp_counter="" otp_issuer=""

	otp_accountname="$(npass_urldecode "${BASH_REMATCH[6]}")"
	if [[ -z "$otp_accountname" ]]; then
		otp_accountname="$(npass_urldecode "${BASH_REMATCH[4]}")"
	else
		otp_issuer="$(npass_urldecode "${BASH_REMATCH[4]}")"
	fi
	[[ -z "$otp_accountname" ]] && npass_die "URI OTP inválida (sem accountname)"

	local p="${BASH_REMATCH[9]}"
	local -a params
	IFS='&' read -r -a params <<<"$p"
	pattern='^([^=]+)=(.+)$'
	local param
	for param in "${params[@]}"; do
		[[ "$param" =~ $pattern ]] || continue
		case "${BASH_REMATCH[1]}" in
		secret) otp_secret="${BASH_REMATCH[2]}" ;;
		digits) otp_digits="${BASH_REMATCH[2]}" ;;
		algorithm) otp_algorithm="${BASH_REMATCH[2]}" ;;
		period) otp_period="${BASH_REMATCH[2]}" ;;
		counter) otp_counter="${BASH_REMATCH[2]}" ;;
		issuer) otp_issuer="$(npass_urldecode "${BASH_REMATCH[2]}")" ;;
		esac
	done

	[[ -z "$otp_secret" ]] && npass_die "URI OTP inválida (sem secret)"
	if [[ "$otp_type" == hotp && ! "$otp_counter" =~ ^[0-9]+$ ]]; then
		npass_die "URI OTP inválida (hotp sem counter)"
	fi
}

npass_otp_read_uri() {
	local prompt="$1" uri uri2
	read -r -s -p "URI otpauth:// para $prompt: " uri || exit 1
	echo
	read -r -s -p "Repita a URI: " uri2 || exit 1
	echo
	[[ "$uri" == "$uri2" ]] || npass_die "as URIs não coincidem"
	otp_parse_uri "$uri"
}

npass_otp_read_secret() {
	local prompt="$1" issuer="$2" account="$3" secret secret2
	read -r -s -p "Secret TOTP para $prompt: " secret || exit 1
	echo
	read -r -s -p "Repita o secret: " secret2 || exit 1
	echo
	[[ "$secret" == "$secret2" ]] || npass_die "os secrets não coincidem"
	local sep=""
	[[ -n "$issuer" && -n "$account" ]] && sep=":"
	local uri
	uri="otpauth://totp/$(npass_urlencode "$issuer")${sep}$(npass_urlencode "$account")?secret=$(npass_urlencode "$secret")"
	[[ -n "$issuer" ]] && uri="${uri}&issuer=$(npass_urlencode "$issuer")"
	otp_parse_uri "$uri"
}

# Pick how to invoke the code generator WITHOUT ever putting the secret
# on argv. Sets NPASS_OTP_CMD (array) and NPASS_OTP_STDIN (0/1: whether
# the secret must be piped to it).
npass_otp_pick_backend() {
	if [[ -n "$OTPTOOL" ]]; then
		NPASS_OTP_CMD=("$OTPTOOL" "$otp_uri")
		NPASS_OTP_STDIN=0
		return 0
	fi
	[[ -z "$OATH" ]] && npass_die "nenhum gerador de OTP disponível (instale oathtool ou otptool)"
	local ver
	ver="$("$OATH" --version | head -n1 | awk '{print $NF}')"
	if ! npass_version_ge "$ver" "$NPASS_OATH_MIN_STDIN_VERSION"; then
		npass_die "oathtool $ver é antigo demais para ler o secret via stdin com segurança (mínimo $NPASS_OATH_MIN_STDIN_VERSION); npass não expõe o secret na linha de comando. Atualize o oathtool ou instale otptool."
	fi
	NPASS_OTP_CMD=("$OATH" --base32)
	case "$otp_type" in
	totp)
		if [[ -n "$otp_algorithm" ]]; then
			NPASS_OTP_CMD+=(--totp="$(tr '[:upper:]' '[:lower:]' <<<"$otp_algorithm")")
		else
			NPASS_OTP_CMD+=(--totp)
		fi
		[[ -n "$otp_period" ]] && NPASS_OTP_CMD+=(--time-step-size="${otp_period}s")
		;;
	hotp)
		NPASS_OTP_CMD+=(--hotp --counter="$((otp_counter + 1))")
		;;
	esac
	[[ -n "$otp_digits" ]] && NPASS_OTP_CMD+=(--digits="$otp_digits")
	NPASS_OTP_CMD+=(-) # secret read from stdin, never from argv
	NPASS_OTP_STDIN=1
}

npass_otp_generate() {
	npass_otp_pick_backend
	local out
	if [[ $NPASS_OTP_STDIN -eq 1 ]]; then
		out="$("${NPASS_OTP_CMD[@]}" <<<"$otp_secret")" || npass_die "falha ao gerar código OTP"
	else
		out="$("${NPASS_OTP_CMD[@]}")" || npass_die "falha ao gerar código OTP"
	fi
	printf '%s\n' "$out"
}

# --- content helpers: an OTP URI lives as an "otpauth://" line inside
# the same multi-line blob a normal password uses (line 1 = password,
# if any; any otpauth:// line = the OTP key). ---------------------------

npass_otp_extract_uri() {
	local content="$1" line
	while IFS= read -r line; do
		[[ "$line" == otpauth://* ]] && { printf '%s\n' "$line"; return 0; }
	done <<<"$content"
	return 1
}

npass_otp_replace_or_append_uri() {
	local content="$1" new_uri="$2" found=0 out="" line
	while IFS= read -r line; do
		if [[ "$line" == otpauth://* ]]; then
			line="$new_uri"
			found=1
		fi
		out+="$line"$'\n'
	done <<<"$content"
	[[ $found -eq 0 ]] && out+="$new_uri"$'\n'
	printf '%s' "$out"
}

# --- commands --------------------------------------------------------------

cmd_otp_code() {
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass otp ID DIR/PASS"
	local dir; dir="$(npass_identity_dir "$id")"
	local content; content="$(cmd_show "$id" "$logical")" || return 1
	local uri; uri="$(npass_otp_extract_uri "$content")" || npass_die "$id: $logical não tem segredo OTP"
	otp_parse_uri "$uri"
	local code; code="$(npass_otp_generate)"

	if [[ "$otp_type" == hotp ]]; then
		local new_counter=$((otp_counter + 1))
		local new_uri
		# NOT ${uri/&counter=$otp_counter/&counter=$new_counter}: on bash
		# 5.2+, `patsub_replacement` is on by default and makes `&` in
		# the REPLACEMENT mean "the matched text", exactly like sed. That
		# turns this into "&counter=5counter=6" - a silently corrupted
		# URI that breaks HOTP sync on the next call. Confirmed against
		# bash 5.2.21. Rebuild the URI via regex capture instead, which
		# has no dependency on that shopt.
		if [[ "$uri" =~ ^(.*)\&counter=[0-9]+(.*)$ ]]; then
			new_uri="${BASH_REMATCH[1]}&counter=${new_counter}${BASH_REMATCH[2]}"
		else
			npass_die "$id: $logical: URI HOTP sem parâmetro counter"
		fi
		local new_content; new_content="$(npass_otp_replace_or_append_uri "$content" "$new_uri")"
		npass_blob_write "$dir" "$logical" "$new_content"
		npass_git_commit "$id" "otp-counter"
	fi
	printf '%s\n' "$code"
}

cmd_otp_clip() {
	local id="$1" logical="$2"
	local code; code="$(cmd_otp_code "$id" "$logical")" || return 1
	npass_clip "$code" "OTP $id: $logical"
}

cmd_otp_uri() {
	local mode="show" id logical
	while [[ "$1" == -* ]]; do
		case "$1" in
		-c | --clip) mode="clip"; shift ;;
		-q | --qrcode) mode="qrcode"; shift ;;
		*) npass_die "opção desconhecida: $1" ;;
		esac
	done
	id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass otp-uri [-c|-q] ID DIR/PASS"
	local content; content="$(cmd_show "$id" "$logical")" || return 1
	local uri; uri="$(npass_otp_extract_uri "$content")" || npass_die "$id: $logical não tem segredo OTP"
	case "$mode" in
	clip) npass_clip "$uri" "URI OTP $id: $logical" ;;
	qrcode)
		command -v qrencode >/dev/null 2>&1 || npass_die "qrencode não encontrado"
		qrencode -t ANSIUTF8 <<<"$uri"
		;;
	*) printf '%s\n' "$uri" ;;
	esac
}

cmd_otp_insert() {
	local force=0 from_secret=0 issuer="" account=""
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		-s | --secret) from_secret=1; shift ;;
		-i | --issuer) issuer="$2"; shift 2 ;;
		-a | --account) account="$2"; shift 2 ;;
		--) shift; break ;;
		*) npass_die "opção desconhecida: $1" ;;
		esac
	done
	local id="$1" logical="$2"
	[[ -z "$id" || -z "$logical" ]] && npass_die "uso: npass otp-insert [-f] [-s -i issuer -a account] ID DIR/PASS"
	local dir; dir="$(npass_identity_dir "$id")"
	local existing; existing="$(cmd_show "$id" "$logical" 2>/dev/null || true)"
	if [[ -n "$existing" ]] && npass_otp_extract_uri "$existing" >/dev/null 2>&1 && [[ $force -eq 0 ]]; then
		read -r -p "$id: $logical já tem um segredo OTP. Sobrescrever? [y/N] " reply
		[[ "$reply" == [yY] ]] || { echo "Cancelado."; return 1; }
	fi

	if [[ $from_secret -eq 1 ]]; then
		[[ -z "$issuer" && -z "$account" ]] && npass_die "informe --issuer ou --account"
		npass_otp_read_secret "$id: $logical" "$issuer" "$account"
	else
		npass_otp_read_uri "$id: $logical"
	fi

	local new_content
	if [[ -n "$existing" ]]; then
		new_content="$(npass_otp_replace_or_append_uri "$existing" "$otp_uri")"
	else
		new_content="$otp_uri"
	fi
	npass_blob_write "$dir" "$logical" "$new_content"
	npass_git_commit "$id" "otp-insert"
	printf '%s: %s (OTP) salvo.\n' "$id" "$logical"
}

cmd_otp_validate() {
	otp_parse_uri "$1"
	printf 'URI OTP válida: tipo=%s conta=%s\n' "$otp_type" "$otp_accountname"
}
