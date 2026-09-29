#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	export FPR2="9768F5A5986075BB78D37BC9DB0594DE5B86B960"
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
	run "$NPASS" show personal email/gmail
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
	run "$NPASS" show personal email/gmail-novo
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
	run "$NPASS" show work aws/root
	[ "$output" = "hunter2" ]
	run "$NPASS" show personal email/gmail
	[ "$status" -ne 0 ]
}

@test "ls so mostra entradas da identidade pedida" {
	"$NPASS" init personal "$FPR"
	"$NPASS" init work "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	printf 'b\nb\n' | "$NPASS" insert work aws/root
	run "$NPASS" ls personal
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
	run "$NPASS" ls personal naoexiste
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
	run "$NPASS" show work email/gmail
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
	[[ "$output" == *"7EBEE20874B9F237"* ]]
	[[ "$output" != *"80011E115B4591BE"* ]]

	run "$NPASS" show work aws/root
	[ "$status" -eq 0 ]
	[ "$output" = "segredo-x" ]
}

@test "insert duplicado sem -f pede confirmacao e aborta em N" {
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	run bash -c "printf 'N\n' | '$NPASS' insert personal email/gmail"
	[ "$status" -ne 0 ]
	run "$NPASS" show personal email/gmail
	[ "$output" = "a" ]
}
