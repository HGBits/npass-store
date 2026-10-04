#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	npass_test_install_ext npass-import || return 1
	export OLD_STORE="$BATS_TEST_TMPDIR/old-pass-store"
	mkdir -p "$OLD_STORE/email" "$OLD_STORE/work/aws"
	printf '%s\n' "$FPR" >"$OLD_STORE/.gpg-id"
	printf 'senhaGmail1\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/email/gmail.gpg"
	printf 'senhaOutlook2\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/email/outlook.gpg"
	printf 'senhaAws3\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/work/aws/root.gpg"
}

@test "import pass cria a identidade automaticamente a partir do .gpg-id antigo" {
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id" ]
}

@test "import pass importa todos os arquivos com caminho logico preservado" {
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
	run "$NPASS" show personal email/outlook
	[ "$output" = "senhaOutlook2" ]
	run "$NPASS" show personal work/aws/root
	[ "$output" = "senhaAws3" ]
}

@test "import pass obscurece o nome fisico do blob (gmail nao aparece no nome do arquivo)" {
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	run find "$NPASS_STORE/personal/blobs" -type f
	[[ "$output" =~ blobs/[A-Z][a-z]{5,8}\.gpg ]]
	[[ "$output" != *gmail* ]]
	[[ "$output" != *outlook* ]]
	[[ "$output" != *aws* ]]
}

@test "import pass sem -f nao sobrescreve entrada ja existente" {
	"$NPASS" init personal "$FPR"
	printf 'jasalvo\njasalvo\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	# o usuario precisa VER que pulou (a senha tambem seria protegida pelo core, que
	# nao sobrescreve sem -f; o aviso e a contagem sao responsabilidade da extensao)
	[[ "$output" == *"email/gmail já existe em personal"* ]]
	[[ "$output" == *"2 importado(s), 1 pulado(s), 0 falhou(aram)"* ]]
	run "$NPASS" show personal email/gmail
	[ "$output" = "jasalvo" ]
}

@test "import pass -f sobrescreve entrada ja existente" {
	"$NPASS" init personal "$FPR"
	printf 'antigo\nantigo\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" import pass -f personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "import pass sem --delete-source preserva os arquivos antigos" {
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	[ -f "$OLD_STORE/email/gmail.gpg" ]
}

@test "import pass --delete-source apaga os arquivos antigos apos importar" {
	"$NPASS" import pass --delete-source personal "$OLD_STORE" >/dev/null
	[ ! -f "$OLD_STORE/email/gmail.gpg" ]
	[ ! -f "$OLD_STORE/work/aws/root.gpg" ]
}

@test "import pass relata falha de decifragem sem abortar as demais entradas" {
	echo "isto nao e gpg valido" > "$OLD_STORE/email/corrompido.gpg"
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"1 falhou"* ]] || [[ "$output" == *"falhou"* ]]
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "migracao com .gpg-id.sig na origem assina a identidade nova automaticamente" {
	printf '%s\n' "$FPR" > "$OLD_STORE/.gpg-id"
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$OLD_STORE/.gpg-id.sig" "$OLD_STORE/.gpg-id"
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id.sig" ]
	run gpg --batch --verify "$NPASS_STORE/personal/.gpg-id.sig" "$NPASS_STORE/personal/.gpg-id"
	[ "$status" -eq 0 ]
}

@test "migracao sem .gpg-id.sig na origem nao assina a identidade nova" {
	[ ! -f "$OLD_STORE/.gpg-id.sig" ]
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "migracao para identidade JA EXISTENTE nunca assina como efeito colateral, mesmo com .gpg-id.sig na origem" {
	"$NPASS" init personal "$FPR"
	printf '%s\n' "$FPR" > "$OLD_STORE/.gpg-id"
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$OLD_STORE/.gpg-id.sig" "$OLD_STORE/.gpg-id"
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "import pass para identidade que ja existe com chave diferente recifra corretamente" {
	"$NPASS" init work "$FPR2"
	run "$NPASS" import pass work "$OLD_STORE"
	[ "$status" -eq 0 ]
	run "$NPASS" show work email/gmail
	[ "$output" = "senhaGmail1" ]
	local blob; blob="$(find "$NPASS_STORE/work/blobs" -type f | head -1)"
	run gpg --list-packets "$blob"
	[[ "$output" == *"$(npass_test_encr_keyid "$FPR2")"* ]]
}

# --- comportamento novo da implementacao na extensao -----------------------------

@test "--dry-run lista o que faria, nao cria a identidade, nao grava e nao decifra nada" {
	run "$NPASS" import pass personal "$OLD_STORE" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"+ email/gmail"* ]]
	[[ "$output" == *"+ work/aws/root"* ]]
	[[ "$output" != *"senhaGmail1"* ]]
	[ ! -e "$NPASS_STORE/personal" ]
}

@test "-p coloca tudo sob um prefixo" {
	"$NPASS" import pass personal "$OLD_STORE" -p Antigo
	run "$NPASS" ls personal
	[[ "$output" == *"Antigo/email/gmail"* ]]
	run "$NPASS" show personal Antigo/email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "importar uma arvore inteira e UM commit" {
	"$NPASS" init personal "$FPR" >/dev/null
	local antes; antes="$(git -C "$NPASS_STORE" rev-list --count HEAD)"
	"$NPASS" import pass personal "$OLD_STORE"
	[ "$(git -C "$NPASS_STORE" rev-list --count HEAD)" -eq $((antes + 1)) ]
}

@test "diretorio de origem inexistente falha citando o diretorio" {
	run "$NPASS" import pass personal "$BATS_TEST_TMPDIR/nao-existe"
	[ "$status" -ne 0 ]
	[[ "$output" == *"nao-existe"* ]]
}

@test "identidade inexistente e origem sem .gpg-id: erro claro, nada criado" {
	rm -f "$OLD_STORE/.gpg-id"
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -ne 0 ]
	[[ "$output" == *".gpg-id"* ]]
	[ ! -e "$NPASS_STORE/personal" ]
}

@test "origem sem nenhum .gpg avisa e nao falha" {
	local vazio="$BATS_TEST_TMPDIR/vazio"
	mkdir -p "$vazio"
	printf '%s\n' "$FPR" >"$vazio/.gpg-id"
	run "$NPASS" import pass personal "$vazio"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nenhum arquivo .gpg"* ]]
}

@test "nome de arquivo com TAB e pulado e relatado; os demais entram (nao aborta o lote)" {
	printf 'x\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/email/a"$'\t'"b.gpg"
	run "$NPASS" import pass personal "$OLD_STORE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"inválido"* ]]
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "symlinks .gpg e o diretorio .git da origem sao ignorados" {
	ln -s "$OLD_STORE/email/gmail.gpg" "$OLD_STORE/email/atalho.gpg"
	mkdir -p "$OLD_STORE/.git"
	printf 'x\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/.git/dentro.gpg"
	"$NPASS" import pass personal "$OLD_STORE" >/dev/null
	run "$NPASS" ls personal
	[[ "$output" != *"atalho"* ]]
	[[ "$output" != *"dentro"* ]]
	[[ "$output" == *"email/gmail"* ]]
}

@test "npass migrate (comando antigo) aponta para a extensao em vez de 'desconhecido'" {
	run "$NPASS" migrate personal "$OLD_STORE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"npass-import"* ]]
	[[ "$output" == *"npass import pass"* ]]
}
