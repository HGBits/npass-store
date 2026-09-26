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
			npass_identity_init "$id" "${recipients[@]}"
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
