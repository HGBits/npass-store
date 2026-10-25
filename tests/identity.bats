#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
}

@test "init cria identidade com .gpg-id e mapa vazio" {
	run "$NPASS" init personal "$FPR"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id" ]
	[ -f "$NPASS_STORE/personal/.map.gpg" ]
}

@test "comando sem ID falha (não existe modo classico)" {
	"$NPASS" init personal "$FPR"
	run "$NPASS" show email/gmail
	[ "$status" -ne 0 ]
}

@test "insert + show roundtrip" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" get personal email/gmail
	[ "$status" -eq 0 ]
	[ "$output" = "hunter2" ]
}

@test "logical path nao aparece no nome fisico do blob" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	run find "$NPASS_STORE/personal/blobs" -type f
	[ "$status" -eq 0 ]
	# nome do blob deve ser um pseudonimo legivel aleatorio ("Bavodu.gpg"), jamais "gmail"
	[[ "$output" =~ blobs/[A-Z][a-z]{5,8}\.gpg$ ]]
	[[ "$output" != *gmail* ]]
	[[ "$output" != *email* ]]
}

@test "rm remove entrada do mapa e o blob fisico" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	local blob
	blob="$(find "$NPASS_STORE/personal/blobs" -type f)"
	"$NPASS" rm -f personal email/gmail
	[ ! -e "$blob" ]
	run "$NPASS" show personal email/gmail
	[ "$status" -ne 0 ]
}

@test "mv na mesma identidade e so edicao de mapa (blob nao muda)" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	local blob_before
	blob_before="$(find "$NPASS_STORE/personal/blobs" -type f)"
	run "$NPASS" mv personal email/gmail email/gmail-novo
	[ "$status" -eq 0 ]
	local blob_after
	blob_after="$(find "$NPASS_STORE/personal/blobs" -type f)"
	[ "$blob_before" = "$blob_after" ]
	run "$NPASS" get personal email/gmail-novo
	[ "$output" = "hunter2" ]
	run "$NPASS" show personal email/gmail
	[ "$status" -ne 0 ]
}

@test "mv entre identidades recifra e some da origem" {
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" mv personal email/gmail work aws/root
	[ "$status" -eq 0 ]
	run "$NPASS" get work aws/root
	[ "$output" = "hunter2" ]
	run "$NPASS" show personal email/gmail
	[ "$status" -ne 0 ]
}

@test "ls so mostra entradas da identidade pedida" {
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	printf 'b\nb\n' | "$NPASS" insert work aws/root
	run "$NPASS" ls --flat personal
	[[ "$output" == *"email/gmail"* ]]
	[[ "$output" != *"aws/root"* ]]
}

@test "git log nao deve conter nomes logicos (sem repo git ainda, checa ausencia de vazamento em claro no store)" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	# nenhum arquivo em texto plano no store deve conter a string "gmail"
	run grep -rl "gmail" "$NPASS_STORE"
	[ "$status" -ne 0 ]
}

@test "ls com prefixo sem match retorna vazio, nao a lista inteira (regressao SC2015)" {
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" ls --flat personal naoexiste
	[[ "$output" != *"email/gmail"* ]]
}

@test "npass_read_gpg_id funciona com variavel de nome diferente de 'dir' no chamador (regressao escopo local)" {
	# Chama a cadeia show->identity_dir->read_gpg_id a partir de um
	# contexto cuja variavel local NAO se chama "dir", para garantir que
	# a resolucao de .gpg-id nao depende de reuso acidental de nome.
	# cmd_mv chama npass_read_gpg_id "$dst_dir" (nao "$dir") ao gravar na
	# identidade de destino - se o bug de escopo local voltar, o .gpg-id
	# lido sera vazio/errado e a criptografia falha.
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	"$NPASS" init work "$FPR"
	run "$NPASS" mv personal email/gmail work email/gmail
	[ "$status" -eq 0 ]
	run "$NPASS" get work email/gmail
	[ "$output" = "a" ]
}

@test "mv entre identidades com chaves DIFERENTES recifra para o destinatario certo (regressao escopo local em npass_read_gpg_id)" {
	# cmd_mv le o .gpg-id via npass_read_gpg_id "$dst_dir" - uma variavel
	# que NAO se chama "dir". Se o bug de escopo local (SC2318) voltar,
	# o segredo movido sera cifrado com a chave da identidade de ORIGEM
	# em vez da de DESTINO, e isso so aparece quando as chaves diferem.
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR2"
	printf 'segredo-x\nsegredo-x\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" mv personal email/gmail work aws/root
	[ "$status" -eq 0 ]

	local blob
	blob="$(find "$NPASS_STORE/work/blobs" -type f)"
	run gpg --list-packets "$blob"
	[[ "$output" == *"$(npass_test_encr_keyid "$FPR2")"* ]]
	[[ "$output" != *"$(npass_test_encr_keyid "$FPR")"* ]]

	run "$NPASS" get work aws/root
	[ "$status" -eq 0 ]
	[ "$output" = "segredo-x" ]
}

@test "insert duplicado sem -f pede confirmacao e aborta em N" {
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	run bash -c "printf 'N\n' | '$NPASS' insert personal email/gmail"
	[ "$status" -ne 0 ]
	run "$NPASS" get personal email/gmail
	[ "$output" = "a" ]
}

# --- identities rename -----------------------------------------------------------------

@test "identities rename: entradas lidas pelo novo nome, nome antigo some, nada e recifrado (mesmos inodes)" {
	"$NPASS" init personal "$FPR"
	printf 'hunter2\nhunter2\n' | "$NPASS" insert personal email/gmail
	local antes depois
	antes="$(cd "$NPASS_STORE/personal" && stat -c '%n %i %Y' .map.gpg .gpg-id blobs/*.gpg | sort)"
	run "$NPASS" identities rename personal pessoal
	[ "$status" -eq 0 ]
	[[ "$output" == *"renomeada"* ]]
	[ ! -e "$NPASS_STORE/personal" ]
	depois="$(cd "$NPASS_STORE/pessoal" && stat -c '%n %i %Y' .map.gpg .gpg-id blobs/*.gpg | sort)"
	[ "$antes" = "$depois" ]
	[ "$("$NPASS" get pessoal email/gmail)" = "hunter2" ]
	run "$NPASS" get personal email/gmail
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade não encontrada"* ]]
	run "$NPASS" identities
	[[ "$output" == *"pessoal"* && "$output" != *"personal"* ]]
}

@test "identities rename: identidade assinada continua valida e aceita escrita; ids e --help funcionam" {
	"$NPASS" init --sign personal "$FPR"
	run "$NPASS" ids rename personal pessoal
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/pessoal/.gpg-id.sig" ]
	run gpg --batch --verify "$NPASS_STORE/pessoal/.gpg-id.sig" "$NPASS_STORE/pessoal/.gpg-id"
	[ "$status" -eq 0 ]
	run bash -c "printf 'x1\nx1\n' | '$NPASS' insert pessoal a/b"
	[ "$status" -eq 0 ]
	run "$NPASS" identities rename --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"uso: npass identities rename"* ]]
}

@test "identities rename: vira um commit 'rename: ANTIGO -> NOVO', sem caminho logico, e nada fica sem commitar" {
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	"$NPASS" identities rename personal pessoal
	run git -C "$NPASS_STORE" log -1 --format=%s
	[ "$output" = "rename: personal -> pessoal" ]
	[[ "$output" != *"email"* ]]
	run git -C "$NPASS_STORE" status --porcelain -- personal pessoal
	[ -z "$output" ]
	run git -C "$NPASS_STORE" show --stat --format= -M HEAD
	[[ "$output" == *"=>"* ]]
}

@test "identities rename: erros (inexistente, destino existe, nome invalido, mesmo nome, sem argumentos)" {
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR"
	run "$NPASS" identities rename naoexiste novo
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade não encontrada"* ]]
	run "$NPASS" identities rename personal work
	[ "$status" -ne 0 ]
	[[ "$output" == *"já existe"* ]]
	local n
	for n in a/b .oculta extensions ..; do
		run "$NPASS" identities rename personal "$n"
		[ "$status" -ne 0 ]
		[ -d "$NPASS_STORE/personal" ]
	done
	run "$NPASS" identities rename personal personal
	[ "$status" -ne 0 ]
	[[ "$output" == *"igual ao atual"* ]]
	run "$NPASS" identities rename personal
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso: npass identities rename"* ]]
	[ -d "$NPASS_STORE/personal" ] && [ -d "$NPASS_STORE/work" ]
}

@test "identities rename: com a trava do mapa ocupada por outro npass, recusa e nada muda" {
	"$NPASS" init personal "$FPR"
	flock -x "$NPASS_STORE/personal/.map.lock" sleep 20 &
	local holder=$!
	sleep 0.5
	run "$NPASS" identities rename personal pessoal
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null || true
	[ "$status" -ne 0 ]
	[[ "$output" == *"em uso"* ]]
	[ -d "$NPASS_STORE/personal" ]
	[ ! -e "$NPASS_STORE/pessoal" ]
}

@test "identities rename: avisa de passkeys quando a identidade tem Fido/" {
	"$NPASS" init personal "$FPR"
	mkdir -p "$NPASS_STORE/personal/Fido"
	run "$NPASS" identities rename personal pessoal
	[ "$status" -eq 0 ]
	[[ "$output" == *"passkeys"* ]]
}
