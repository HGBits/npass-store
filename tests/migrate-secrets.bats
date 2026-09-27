#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	export FPR2="9768F5A5986075BB78D37BC9DB0594DE5B86B960"
	mkdir -p "$NPASS_STORE"

	export OLD="$BATS_TEST_TMPDIR/old-secrets-store"
	mkdir -p "$OLD/IST" "$OLD/LOFT" "$OLD/OPEX" "$OLD/STR" "$OLD/YEN"
	printf '%s\n' "$FPR" >"$OLD/.gpg-id"

	# .secrets.gpg: exemplos reais do formato "CODINOME = Nome Real"
	printf 'IST/Bvop = 99\nLOFT/Zen = Amazon\nLOFT/Ziode = Americanas\nOPEX/Anpiong = Gov.br\nSTR/As = Retroachiviements\nYEN/Yu = Wallet of Satoshi\n' \
		| gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/.secrets.gpg"

	# .mask.gpg: alias de email so para IST e LOFT (OPEX/STR/YEN ficam sem)
	printf 'IST = ist-alias@simplelogin.io\nLOFT = loft-alias@simplelogin.io\n' \
		| gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/.mask.gpg"

	printf 'senha99\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/IST/Bvop.gpg"
	printf 'senhaAmazon\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/LOFT/Zen.gpg"
	printf 'senhaAmericanas\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/LOFT/Ziode.gpg"
	printf 'senhaGovBr\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/OPEX/Anpiong.gpg"
	printf 'senhaRetro\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/STR/As.gpg"
	printf 'senhaSatoshi\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/YEN/Yu.gpg"
}

@test "migrate-secrets cria a identidade automaticamente a partir do .gpg-id antigo" {
	run "$NPASS" migrate-secrets personal "$OLD"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id" ]
}

@test "o caminho logico continua sendo o codinome, NUNCA o nome real" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal IST/Bvop
	[ "$status" -eq 0 ]
	run "$NPASS" show personal 99
	[ "$status" -ne 0 ]
	run "$NPASS" ls personal
	[[ "$output" == *"IST/Bvop"* ]]
	[[ "$output" != *"Amazon"* ]]
}

@test "show traz a senha original E a nota de nome real junto" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal LOFT/Zen
	[ "$status" -eq 0 ]
	[[ "$output" == *"senhaAmazon"* ]]
	[[ "$output" == *"nome-real: Amazon"* ]]
}

@test "categoria com mask.gpg ganha nota de alias de email, categoria sem mask nao ganha" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal LOFT/Zen
	[[ "$output" == *"email-alias: loft-alias@simplelogin.io"* ]]
	run "$NPASS" show personal STR/As
	[[ "$output" != *"email-alias"* ]]
	[[ "$output" == *"nome-real: Retroachiviements"* ]]
}

@test "nome real com valor puramente numerico (99) e importado corretamente" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal IST/Bvop
	[[ "$output" == *"senha99"* ]]
	[[ "$output" == *"nome-real: 99"* ]]
}

@test "grep encontra a entrada pelo NOME REAL mesmo arquivada sob o codinome" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" grep personal "Wallet of Satoshi"
	[ "$status" -eq 0 ]
	[[ "$output" == *"YEN/Yu"* ]]
}

@test "blob fisico continua opaco (nome real e codinome nao aparecem no nome do arquivo)" {
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run find "$NPASS_STORE/personal/blobs" -type f
	[[ "$output" =~ blobs/[0-9a-f]{32}\.gpg ]]
	[[ "$output" != *Bvop* ]]
	[[ "$output" != *Amazon* ]]
	[[ "$output" != *Zen* ]]
}

@test "entrada sem correspondencia no .secrets.gpg importa normalmente, sem nota de nome real" {
	mkdir -p "$OLD/ORFAO"
	printf 'senhaOrfa\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$OLD/ORFAO/Xyz.gpg"
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal ORFAO/Xyz
	[ "$status" -eq 0 ]
	[[ "$output" == *"senhaOrfa"* ]]
	[[ "$output" != *"nome-real"* ]]
}

@test "sem .secrets.gpg nenhum, migra tudo mesmo assim sem nenhuma nota" {
	rm "$OLD/.secrets.gpg"
	run "$NPASS" migrate-secrets personal "$OLD"
	[ "$status" -eq 0 ]
	run "$NPASS" show personal IST/Bvop
	[[ "$output" == *"senha99"* ]]
	[[ "$output" != *"nome-real"* ]]
}

@test "sem -f nao sobrescreve entrada ja existente" {
	"$NPASS" init personal "$FPR"
	printf 'jasalvo\njasalvo\n' | "$NPASS" insert personal IST/Bvop
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	run "$NPASS" show personal IST/Bvop
	[ "$output" = "jasalvo" ]
}

@test "-f sobrescreve entrada ja existente, incluindo a nota de nome real" {
	"$NPASS" init personal "$FPR"
	printf 'antigo\nantigo\n' | "$NPASS" insert personal IST/Bvop
	"$NPASS" migrate-secrets -f personal "$OLD" >/dev/null
	run "$NPASS" show personal IST/Bvop
	[[ "$output" == *"senha99"* ]]
	[[ "$output" == *"nome-real: 99"* ]]
}

@test "--delete-source apaga os arquivos antigos, .secrets.gpg e .mask.gpg permanecem" {
	"$NPASS" migrate-secrets --delete-source personal "$OLD" >/dev/null
	[ ! -f "$OLD/IST/Bvop.gpg" ]
	[ -f "$OLD/.secrets.gpg" ]
	[ -f "$OLD/.mask.gpg" ]
}

@test "arquivo corrompido nao aborta a migracao das demais entradas" {
	echo "nao e gpg valido" > "$OLD/IST/corrompido.gpg"
	run "$NPASS" migrate-secrets personal "$OLD"
	[ "$status" -ne 0 ]
	run "$NPASS" show personal IST/Bvop
	[ "$status" -eq 0 ]
}

@test "migrate-secrets com .gpg-id.sig na origem assina a identidade nova automaticamente" {
	gpg --batch --yes --default-key "$FPR" --detach-sign -o "$OLD/.gpg-id.sig" "$OLD/.gpg-id"
	run "$NPASS" migrate-secrets personal "$OLD"
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id.sig" ]
	run gpg --batch --verify "$NPASS_STORE/personal/.gpg-id.sig" "$NPASS_STORE/personal/.gpg-id"
	[ "$status" -eq 0 ]
}

@test "migrate-secrets sem .gpg-id.sig na origem nao assina a identidade nova" {
	[ ! -f "$OLD/.gpg-id.sig" ]
	"$NPASS" migrate-secrets personal "$OLD" >/dev/null
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "migracao para identidade com chave diferente recifra corretamente" {
	"$NPASS" init work "$FPR2"
	run "$NPASS" migrate-secrets work "$OLD"
	[ "$status" -eq 0 ]
	run "$NPASS" show work LOFT/Zen
	[[ "$output" == *"senhaAmazon"* ]]
	local blob; blob="$(find "$NPASS_STORE/work/blobs" -type f | head -1)"
	run gpg --list-packets "$blob"
	[[ "$output" == *"7EBEE20874B9F237"* ]]
}
