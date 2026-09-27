#!/usr/bin/env bash
# npass - migrate: import a legacy pass-style store (real directory tree,
# where directory/file names ARE the plaintext logical names) into an
# npass identity, obscuring every name behind the map.
#
# Scope note: this migrates from a VANILLA pass layout
# ($PREFIX/some/dir/name.gpg). If you're coming from a specific
# name-obscuring extension with its own lookup-table format, that
# format needs its own importer - tell me its layout and I'll add one;
# guessing at an undocumented format here would risk silently importing
# the wrong logical names.

cmd_migrate_usage() {
	cat <<-_EOF
		Uso: npass migrate [-f] [--delete-source] ID DIRETÓRIO_ANTIGO

		Importa um store pass tradicional (diretórios/arquivos .gpg com nomes
		em texto claro) para dentro da identidade ID, obscurecendo cada nome
		lógico no mapa. Cada arquivo <caminho>.gpg em DIRETÓRIO_ANTIGO vira
		a entrada lógica "<caminho>" na identidade de destino.

		  -f, --force          sobrescreve entradas já existentes em ID
		      --delete-source  apaga (shred) o .gpg antigo após importar com sucesso
		                       (desligado por padrão - a migração é não destrutiva)

		Se ID ainda não existir e DIRETÓRIO_ANTIGO tiver um .gpg-id, a
		identidade é criada automaticamente com os mesmos destinatários.
	_EOF
}

cmd_migrate() {
	local force=0 delete_source=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		--delete-source) delete_source=1; shift ;;
		-h | --help) cmd_migrate_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" old_dir="$2"
	[[ -z "$id" || -z "$old_dir" ]] && { cmd_migrate_usage; npass_die "$(npass_t erro_informe_id_dir)"; }
	[[ -d "$old_dir" ]] || npass_die "$(npass_t erro_dir_nao_encontrado "$old_dir")"
	old_dir="${old_dir%/}"

	local dir="$NPASS_STORE/$id"
	if [[ ! -f "$dir/.gpg-id" ]]; then
		if [[ -f "$old_dir/.gpg-id" ]]; then
			local -a recipients
			mapfile -t recipients <"$old_dir/.gpg-id"
			# If the source identity was signed, the auto-created
			# destination is born signed too - preserving that intent
			# is the point, not an afterthought. If the identity
			# already existed (no auto-create), we never sign it as a
			# side effect of migrating into it: that decision stays
			# explicit via `npass sign`.
			local -a init_args=()
			[[ -f "$old_dir/.gpg-id.sig" ]] && init_args+=(--sign)
			npass_identity_init "${init_args[@]}" "$id" "${recipients[@]}"
		else
			npass_die "$(npass_t erro_id_sem_auto_criar "$id" "$old_dir")"
		fi
	fi
	dir="$(npass_identity_dir "$id")"

	local -a files=()
	while IFS= read -r -d '' f; do
		files+=("$f")
	done < <(find "$old_dir" -type f -name '*.gpg' -not -path '*/.git/*' -print0)

	if [[ ${#files[@]} -eq 0 ]]; then
		npass_t msg_nenhum_arquivo_gpg "$old_dir"
		return 0
	fi

	local imported=0 skipped=0 failed=0
	local f rel logical existing plaintext
	for f in "${files[@]}"; do
		rel="${f#"$old_dir"/}"
		logical="${rel%.gpg}"

		existing="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)"
		if [[ -n "$existing" && $force -eq 0 ]]; then
			npass_warn "$(npass_t warn_migrate_existe "$logical" "$id")"
			((skipped++))
			continue
		fi

		if ! plaintext="$(npass_gpg_decrypt "$f" 2>/dev/null)"; then
			npass_warn "$(npass_t warn_falha_decifrar "$logical")"
			((failed++))
			continue
		fi

		npass_blob_write "$dir" "$logical" "$plaintext"
		((imported++))

		if [[ $delete_source -eq 1 ]]; then
			shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
		fi
	done

	npass_git_commit "$id" "migrate"
	npass_t msg_migrate_resumo "$id" "$imported" "$skipped" "$failed"
	[[ $failed -gt 0 ]] && return 1
	return 0
}

# --- migrate-secrets: import from the pass-secrets-redesign layout -------
#
# Unlike vanilla pass, that layout already obscures the physical name:
# both the top-level category directory (e.g. "IST") and the leaf
# filename (e.g. "Bvop.gpg") are arbitrary codenames, not the real
# service name. The real name lives separately, in an encrypted lookup
# file (.secrets.gpg, "CODE_PATH = Real Name" per line) meant to be
# consulted on demand rather than memorized. .mask.gpg follows the same
# "codename = real value" shape but keys on the CATEGORY only, holding
# the email alias used for every account registered under it.
#
# Design decision (made with the user, not assumed): the codename stays
# the npass logical path. Using the real name instead was considered
# and rejected, because the logical path is passed as a literal CLI
# argument on every `show`/`edit`/etc. - it would land in shell history
# and /proc/*/cmdline, and could be correlated against git commit
# timestamps to deduce which service a given commit touched, even
# though the commit message itself never names it. The real name and
# email alias are instead appended as plain note lines INSIDE the
# already-encrypted blob, where they're exposed only to whoever already
# decrypted that one secret - no worse than the password itself.
#
# The note-line labels below are intentionally NOT run through npass_t:
# they become permanent data baked into the user's stored secret, not
# transient UI text, so they must not silently change wording depending
# on whatever NPASS_LANG happens to be set at migration time.
readonly NPASS_MIGRATE_SECRETS_LABEL_REAL="nome-real"
readonly NPASS_MIGRATE_SECRETS_LABEL_ALIAS="email-alias"

# Parse a "CODE = value" file (already decrypted) into an associative
# array named by $1, splitting on the FIRST " = " on each line. A value
# that itself contains " = " will mis-split on the last occurrence
# instead - a known, documented limitation of this simple format.
npass_parse_secrets_map() {
	local -n _out="$1"
	local body="$2" line key val
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		if [[ "$line" =~ ^(.+)\ =\ (.+)$ ]]; then
			key="${BASH_REMATCH[1]}"
			val="${BASH_REMATCH[2]}"
			_out["$key"]="$val"
		fi
	done <<<"$body"
}

cmd_migrate_secrets_usage() {
	cat <<-_EOF
		Uso: npass migrate-secrets [-f] [--delete-source] ID DIR_IDENTIDADE_ANTIGA

		Importa uma identidade no layout pass-secrets-redesign: uma árvore onde
		tanto a categoria (diretório) quanto o arquivo já são codinomes, com um
		.secrets.gpg separado traduzindo "CODINOME = Nome Real", e opcionalmente
		um .mask.gpg traduzindo "CATEGORIA = alias-de-email".

		O codinome (ex.: "IST/Bvop") vira o caminho lógico no npass, sem
		mudança nenhuma no que você digita. O nome real e o alias de email,
		quando existirem, são gravados como notas dentro do próprio conteúdo
		cifrado de cada entrada - nunca no mapa, no git, ou na linha de
		comando.

		  -f, --force          sobrescreve entradas já existentes em ID
		      --delete-source  apaga (shred) o .gpg antigo após importar com sucesso
	_EOF
}

cmd_migrate_secrets() {
	local force=0 delete_source=0
	while [[ "$1" == -* ]]; do
		case "$1" in
		-f | --force) force=1; shift ;;
		--delete-source) delete_source=1; shift ;;
		-h | --help) cmd_migrate_secrets_usage; return 0 ;;
		--) shift; break ;;
		*) npass_die "$(npass_t erro_opcao_desconhecida "$1")" ;;
		esac
	done
	local id="$1" old_dir="$2"
	[[ -z "$id" || -z "$old_dir" ]] && { cmd_migrate_secrets_usage; npass_die "$(npass_t erro_informe_id_dir)"; }
	[[ -d "$old_dir" ]] || npass_die "$(npass_t erro_dir_nao_encontrado "$old_dir")"
	old_dir="${old_dir%/}"

	local dir="$NPASS_STORE/$id"
	if [[ ! -f "$dir/.gpg-id" ]]; then
		if [[ -f "$old_dir/.gpg-id" ]]; then
			local -a recipients
			mapfile -t recipients <"$old_dir/.gpg-id"
			# If the source identity was signed, the auto-created
			# destination is born signed too - preserving that intent
			# is the point, not an afterthought. If the identity
			# already existed (no auto-create), we never sign it as a
			# side effect of migrating into it: that decision stays
			# explicit via `npass sign`.
			local -a init_args=()
			[[ -f "$old_dir/.gpg-id.sig" ]] && init_args+=(--sign)
			npass_identity_init "${init_args[@]}" "$id" "${recipients[@]}"
		else
			npass_die "$(npass_t erro_id_sem_auto_criar "$id" "$old_dir")"
		fi
	fi
	dir="$(npass_identity_dir "$id")"

	local -A secrets_map=()
	if [[ -f "$old_dir/.secrets.gpg" ]]; then
		local secrets_body
		if secrets_body="$(npass_gpg_decrypt "$old_dir/.secrets.gpg" 2>/dev/null)"; then
			npass_parse_secrets_map secrets_map "$secrets_body"
		else
			npass_warn "$(npass_t warn_secrets_sem_decifrar)"
		fi
	fi

	local -A mask_map=()
	if [[ -f "$old_dir/.mask.gpg" ]]; then
		local mask_body
		if mask_body="$(npass_gpg_decrypt "$old_dir/.mask.gpg" 2>/dev/null)"; then
			npass_parse_secrets_map mask_map "$mask_body"
		else
			npass_warn "$(npass_t warn_mask_sem_decifrar)"
		fi
	fi

	local -a files=()
	while IFS= read -r -d '' f; do
		case "$f" in
		"$old_dir/.gpg-id" | "$old_dir/.gpg-id.sig" | "$old_dir/.secrets.gpg" | "$old_dir/.mask.gpg") continue ;;
		esac
		files+=("$f")
	done < <(find "$old_dir" -type f -name '*.gpg' -not -path '*/.git/*' -print0)

	if [[ ${#files[@]} -eq 0 ]]; then
		npass_t msg_nenhum_arquivo_gpg "$old_dir"
		return 0
	fi

	local imported=0 skipped=0 failed=0
	local f rel logical category real_name email_alias existing plaintext new_content
	for f in "${files[@]}"; do
		rel="${f#"$old_dir"/}"
		logical="${rel%.gpg}"
		category="${logical%%/*}"

		existing="$(npass_map_resolve "$dir" "$logical" 2>/dev/null)"
		if [[ -n "$existing" && $force -eq 0 ]]; then
			npass_warn "$(npass_t warn_migrate_existe "$logical" "$id")"
			((skipped++))
			continue
		fi

		if ! plaintext="$(npass_gpg_decrypt "$f" 2>/dev/null)"; then
			npass_warn "$(npass_t warn_falha_decifrar "$logical")"
			((failed++))
			continue
		fi

		new_content="$plaintext"
		real_name="${secrets_map[$logical]:-}"
		[[ -n "$real_name" ]] && new_content+=$'\n'"# $NPASS_MIGRATE_SECRETS_LABEL_REAL: $real_name"
		email_alias="${mask_map[$category]:-}"
		[[ -n "$email_alias" ]] && new_content+=$'\n'"# $NPASS_MIGRATE_SECRETS_LABEL_ALIAS: $email_alias"

		npass_blob_write "$dir" "$logical" "$new_content"
		((imported++))

		if [[ $delete_source -eq 1 ]]; then
			shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
		fi
	done

	npass_git_commit "$id" "migrate-secrets"
	npass_t msg_migrate_resumo "$id" "$imported" "$skipped" "$failed"
	[[ $failed -gt 0 ]] && return 1
	return 0
}
