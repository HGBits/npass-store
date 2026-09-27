#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	export FPR2="9768F5A5986075BB78D37BC9DB0594DE5B86B960"
	mkdir -p "$NPASS_STORE"
	export OLD_STORE="$BATS_TEST_TMPDIR/old-pass-store"
	mkdir -p "$OLD_STORE/email" "$OLD_STORE/work/aws"
	printf '%s\n' "$FPR" >"$OLD_STORE/.gpg-id"
	printf 'senhaGmail1\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/email/gmail.gpg"
	printf 'senhaOutlook2\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/email/outlook.gpg"
	printf 'senhaAws3\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD_STORE/work/aws/root.gpg"
}

@test "migrate cria a identidade automaticamente a partir do .gpg-id antigo" {
	run "$NPASS" migrate personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id" ]
}

@test "migrate importa todos os arquivos com caminho logico preservado" {
	"$NPASS" migrate personal "$OLD_STORE" >/dev/null
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
	run "$NPASS" show personal email/outlook
	[ "$output" = "senhaOutlook2" ]
	run "$NPASS" show personal work/aws/root
	[ "$output" = "senhaAws3" ]
}

@test "migrate obscurece o nome fisico do blob (gmail nao aparece no nome do arquivo)" {
	"$NPASS" migrate personal "$OLD_STORE" >/dev/null
	run find "$NPASS_STORE/personal/blobs" -type f
	[[ "$output" =~ blobs/[0-9a-f]{32}\.gpg ]]
	[[ "$output" != *gmail* ]]
	[[ "$output" != *outlook* ]]
	[[ "$output" != *aws* ]]
}

@test "migrate sem -f nao sobrescreve entrada ja existente" {
	"$NPASS" init personal "$FPR"
	printf 'jasalvo\njasalvo\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" migrate personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	run "$NPASS" show personal email/gmail
	[ "$output" = "jasalvo" ]
}

@test "migrate -f sobrescreve entrada ja existente" {
	"$NPASS" init personal "$FPR"
	printf 'antigo\nantigo\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" migrate -f personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "migrate sem --delete-source preserva os arquivos antigos" {
	"$NPASS" migrate personal "$OLD_STORE" >/dev/null
	[ -f "$OLD_STORE/email/gmail.gpg" ]
}

@test "migrate --delete-source apaga os arquivos antigos apos importar" {
	"$NPASS" migrate --delete-source personal "$OLD_STORE" >/dev/null
	[ ! -f "$OLD_STORE/email/gmail.gpg" ]
	[ ! -f "$OLD_STORE/work/aws/root.gpg" ]
}

@test "migrate relata falha de decifragem sem abortar as demais entradas" {
	echo "isto nao e gpg valido" > "$OLD_STORE/email/corrompido.gpg"
	run "$NPASS" migrate personal "$OLD_STORE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"1 falhou"* ]] || [[ "$output" == *"falhou"* ]]
	run "$NPASS" show personal email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "migracao com .gpg-id.sig na origem assina a identidade nova automaticamente" {
	printf '%s\n' "$FPR" > "$OLD_STORE/.gpg-id"
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$OLD_STORE/.gpg-id.sig" "$OLD_STORE/.gpg-id"
	run "$NPASS" migrate personal "$OLD_STORE"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id.sig" ]
	run gpg --batch --verify "$NPASS_STORE/personal/.gpg-id.sig" "$NPASS_STORE/personal/.gpg-id"
	[ "$status" -eq 0 ]
}

@test "migracao sem .gpg-id.sig na origem nao assina a identidade nova" {
	[ ! -f "$OLD_STORE/.gpg-id.sig" ]
	"$NPASS" migrate personal "$OLD_STORE" >/dev/null
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "migracao para identidade JA EXISTENTE nunca assina como efeito colateral, mesmo com .gpg-id.sig na origem" {
	"$NPASS" init personal "$FPR"
	printf '%s\n' "$FPR" > "$OLD_STORE/.gpg-id"
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$OLD_STORE/.gpg-id.sig" "$OLD_STORE/.gpg-id"
	"$NPASS" migrate personal "$OLD_STORE" >/dev/null
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "migrate para identidade que ja existe com chave diferente recifra corretamente" {
	"$NPASS" init work "$FPR2"
	run "$NPASS" migrate work "$OLD_STORE"
	[ "$status" -eq 0 ]
	run "$NPASS" show work email/gmail
	[ "$output" = "senhaGmail1" ]
	local blob; blob="$(find "$NPASS_STORE/work/blobs" -type f | head -1)"
	run gpg --list-packets "$blob"
	[[ "$output" == *"7EBEE20874B9F237"* ]]
}
