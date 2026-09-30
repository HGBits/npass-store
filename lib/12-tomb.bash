#!/usr/bin/env bash
# npass - per-identity Tomb protection.
#
# A protected identity keeps .gpg-id outside the Tomb and places the encrypted
# map/blob data inside a mounted Tomb. The public paths remain stable through
# relative symlinks:
#
#   ID/
#   ├── .gpg-id
#   ├── .npass.tomb
#   ├── .map.gpg -> .npass-tomb/.map.gpg
#   └── blobs    -> .npass-tomb/blobs
#
# .npass-tomb/ is a mountpoint and is ignored by Git. The Tomb image itself is
# versioned as one opaque file, while the Tomb key stays outside the store and
# is itself encrypted by GPG for the identity recipients.

: "${NPASS_TOMB:=tomb}"
: "${NPASS_TOMB_SIZE:=30}"
: "${NPASS_TOMB_MOUNT:=.npass-tomb}"
: "${NPASS_TOMB_KEY_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/npass/tomb-keys}"

npass_tomb_die() {
	npass_die "tomb: $*"
}

npass_tomb_require_command() {
	command -v "$NPASS_TOMB" >/dev/null 2>&1 || npass_tomb_die "comando '$NPASS_TOMB' não encontrado"
	command -v mountpoint >/dev/null 2>&1 || npass_tomb_die "comando 'mountpoint' não encontrado"
}

npass_tomb_file() {
	local dir="$1"
	printf '%s\n' "$dir/.npass.tomb"
}

npass_tomb_mount() {
	local dir="$1"
	printf '%s\n' "$dir/$NPASS_TOMB_MOUNT"
}

npass_tomb_key_file() {
	local id="$1" digest
	command -v sha256sum >/dev/null 2>&1 || npass_tomb_die "comando 'sha256sum' não encontrado"
	digest="$(printf '%s' "$id" | sha256sum | awk '{print $1}')"
	printf '%s/%s.tomb.key\n' "$NPASS_TOMB_KEY_DIR" "$digest"
}

npass_tomb_is_protected() {
	local dir="$1"
	[[ -f "$(npass_tomb_file "$dir")" ]]
}

npass_tomb_is_open() {
	local dir="$1" mount
	mount="$(npass_tomb_mount "$dir")"
	npass_tomb_require_command
	mountpoint -q "$mount"
}

npass_tomb_require_open() {
	local dir="$1"
	if npass_tomb_is_protected "$dir" && ! npass_tomb_is_open "$dir"; then
		npass_die "$(npass_t erro_tomb_fechado "${dir##*/}")"
	fi
}

npass_tomb_recipients_arg() {
	local -a recipients=("$@")
	local r out=""
	for r in "${recipients[@]}"; do
		[[ -n "$r" ]] || continue
		[[ -n "$out" ]] && out+=,
		out+="$r"
	done
	printf '%s\n' "$out"
}

npass_tomb_links_install() {
	local dir="$1" mount map_link blob_link
	mount="$(npass_tomb_mount "$dir")"
	map_link="$dir/.map.gpg"
	blob_link="$dir/blobs"

	[[ -f "$mount/.map.gpg" ]] || npass_tomb_die "Tomb da identidade '${dir##*/}' não contém .map.gpg"
	[[ -d "$mount/blobs" ]] || npass_tomb_die "Tomb da identidade '${dir##*/}' não contém blobs/"

	if [[ -e "$map_link" || -L "$map_link" ]]; then
		[[ -L "$map_link" ]] || npass_tomb_die "já existe arquivo físico em $map_link"
	else
		ln -s "$NPASS_TOMB_MOUNT/.map.gpg" "$map_link" ||
			npass_tomb_die "falha ao criar link para .map.gpg"
	fi

	if [[ -e "$blob_link" || -L "$blob_link" ]]; then
		[[ -L "$blob_link" ]] || npass_tomb_die "já existe diretório físico em $blob_link"
	else
		ln -s "$NPASS_TOMB_MOUNT/blobs" "$blob_link" ||
			npass_tomb_die "falha ao criar link para blobs/"
	fi
}

npass_tomb_usage() {
	cat <<-_EOF
		Uso:
		  npass tomb create [-s MB] ID
		  npass tomb open ID
		  npass tomb close ID
		  npass tomb status ID
		  npass tomb list

		Cria uma proteção Tomb somente para a identidade informada.
		.gpg-id permanece fora do Tomb; .map.gpg e blobs/ ficam dentro dele.
	_EOF
}

cmd_tomb() {
	local sub="$1"
	shift || true
	case "$sub" in
	create) npass_tomb_create "$@" ;;
	open) npass_tomb_open "$@" ;;
	close) npass_tomb_close "$@" ;;
	status) npass_tomb_status "$@" ;;
	list) npass_tomb_list "$@" ;;
	-h|--help|'') npass_tomb_usage ;;
	*) npass_tomb_die "subcomando desconhecido: $sub" ;;
	esac
}

npass_tomb_create() {
	local size="$NPASS_TOMB_SIZE" id dir tomb key mount recipients_arg
	while [[ "$1" == -* ]]; do
		case "$1" in
		-s|--size) size="$2"; shift 2 ;;
		-h|--help) npass_tomb_usage; return 0 ;;
		*) npass_tomb_die "opção desconhecida: $1" ;;
		esac
	done
	id="$1"
	[[ -n "$id" && -z "$2" ]] || npass_tomb_die "uso: npass tomb create [-s MB] ID"
	[[ "$size" =~ ^[0-9]+$ && "$size" -ge 10 ]] || npass_tomb_die "tamanho do Tomb inválido: $size MB (mínimo 10)"

	dir="$(npass_identity_dir "$id")"
	tomb="$(npass_tomb_file "$dir")"
	mount="$(npass_tomb_mount "$dir")"
	key="$(npass_tomb_key_file "$id")"

	npass_tomb_require_command
	[[ ! -e "$tomb" ]] || npass_tomb_die "a identidade '$id' já possui um Tomb"
	[[ ! -e "$key" ]] || npass_tomb_die "a chave do Tomb já existe: $key"

	npass_read_gpg_id "$dir"
	recipients_arg="$(npass_tomb_recipients_arg "${NPASS_RECIPIENTS[@]}")"
	[[ -n "$recipients_arg" ]] || npass_tomb_die "nenhum destinatário GPG definido"

	mkdir -p -- "$NPASS_TOMB_KEY_DIR" "$mount" || npass_tomb_die "falha ao preparar diretórios do Tomb"
	chmod 700 -- "$NPASS_TOMB_KEY_DIR"

	"$NPASS_TOMB" dig "$tomb" -s "$size" ||
		npass_tomb_die "falha ao criar o arquivo Tomb"
	"$NPASS_TOMB" forge "$key" -gr "$recipients_arg" ||
		npass_tomb_die "falha ao criar a chave do Tomb"
	"$NPASS_TOMB" lock "$tomb" -k "$key" -gr "$recipients_arg" ||
		npass_tomb_die "falha ao inicializar o Tomb"

	if ! "$NPASS_TOMB" open "$tomb" -k "$key" -g "$mount"; then
		rm -f -- "$key" "$tomb"
		rmdir -- "$mount" 2>/dev/null || true
		npass_tomb_die "falha ao abrir o Tomb recém-criado"
	fi

	if ! mv -- "$dir/.map.gpg" "$mount/.map.gpg" ||
		! mv -- "$dir/blobs" "$mount/blobs"; then
		"$NPASS_TOMB" close "${tomb##*/}" >/dev/null 2>&1 || true
		npass_warn "$(npass_t warn_tomb_movimento_parcial)"
		npass_tomb_die "falha ao mover os dados existentes para dentro do Tomb"
	fi

	npass_tomb_links_install "$dir"
	npass_git_commit "$id" "tomb-create"

	printf 'Identidade "%s" protegida com Tomb.\n' "$id"
	printf '  Tomb: %s\n' "$tomb"
	printf '  Chave: %s\n' "$key"
	printf '  Estado: aberto\n'
}

npass_tomb_open() {
	local id="$1" dir tomb key mount
	[[ -n "$id" && -z "$2" ]] || npass_tomb_die "uso: npass tomb open ID"
	dir="$(npass_identity_dir "$id")"
	tomb="$(npass_tomb_file "$dir")"
	mount="$(npass_tomb_mount "$dir")"
	key="$(npass_tomb_key_file "$id")"

	npass_tomb_require_command
	[[ -f "$tomb" ]] || npass_tomb_die "a identidade '$id' não possui Tomb"
	[[ -f "$key" ]] || npass_tomb_die "chave do Tomb não encontrada: $key"
	if npass_tomb_is_open "$dir"; then
		npass_t "msg_tomb_aberto" "$id"
		return 0
	fi

	mkdir -p -- "$mount" || npass_tomb_die "falha ao preparar ponto de montagem"
	"$NPASS_TOMB" open "$tomb" -k "$key" -g "$mount" ||
		npass_tomb_die "falha ao abrir o Tomb da identidade '$id'"
	if ! npass_tomb_links_install "$dir"; then
		"$NPASS_TOMB" close "${tomb##*/}" >/dev/null 2>&1 || true
		exit 1
	fi

	npass_t "msg_tomb_aberto" "$id"
}

npass_tomb_close() {
	local id="$1" dir tomb
	[[ -n "$id" && -z "$2" ]] || npass_tomb_die "uso: npass tomb close ID"
	dir="$(npass_identity_dir "$id")"
	tomb="$(npass_tomb_file "$dir")"

	npass_tomb_require_command
	[[ -f "$tomb" ]] || npass_tomb_die "a identidade '$id' não possui Tomb"
	npass_tomb_is_open "$dir" || { npass_t "msg_tomb_fechado" "$id"; return 0; }

	sync
	"$NPASS_TOMB" close "${tomb##*/}" ||
		npass_tomb_die "falha ao fechar o Tomb da identidade '$id'"
	npass_t "msg_tomb_fechado" "$id"
}

npass_tomb_status() {
	local id="$1" dir
	[[ -n "$id" && -z "$2" ]] || npass_tomb_die "uso: npass tomb status ID"
	dir="$(npass_identity_dir "$id")"
	if ! npass_tomb_is_protected "$dir"; then
		npass_t "msg_tomb_nao_protegido" "$id"
	elif npass_tomb_is_open "$dir"; then
		npass_t "msg_tomb_aberto" "$id"
	else
		npass_t "msg_tomb_fechado" "$id"
	fi
}

npass_tomb_list() {
	[[ -z "$*" ]] || npass_tomb_die "uso: npass tomb list"
	local d id state found=0
	for d in "$NPASS_STORE"/*/; do
		[[ -f "$d/.gpg-id" && -f "$d/.npass.tomb" ]] || continue
		id="${d%/}"
		id="${id##*/}"
		if npass_tomb_is_open "$d"; then
			state="aberto"
		else
			state="fechado"
		fi
		printf '%s - %s\n' "$id" "$state"
		found=1
	done
	[[ $found -eq 1 ]] || npass_t "msg_tomb_nenhum"
}
