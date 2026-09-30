#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
}

@test "identidade sem --sign nao gera .gpg-id.sig" {
	"$NPASS" init personal "$FPR"
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "init --sign gera .gpg-id.sig valido" {
	"$NPASS" init --sign personal "$FPR"
	[ -f "$NPASS_STORE/personal/.gpg-id.sig" ]
	run gpg --batch --verify "$NPASS_STORE/personal/.gpg-id.sig" "$NPASS_STORE/personal/.gpg-id"
	[ "$status" -eq 0 ]
}

@test "identidade nao assinada continua funcionando normalmente (retrocompatibilidade)" {
	"$NPASS" init personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal x/y
	run "$NPASS" show personal x/y
	[ "$status" -eq 0 ]
	[ "$output" = "a" ]
}

@test "identidade assinada continua funcionando normalmente quando a assinatura e valida" {
	"$NPASS" init --sign personal "$FPR"
	printf 'a\na\n' | "$NPASS" insert personal x/y
	run "$NPASS" show personal x/y
	[ "$status" -eq 0 ]
	[ "$output" = "a" ]
}

@test "npass sign assina uma identidade ja existente e nao assinada" {
	"$NPASS" init personal "$FPR"
	[ ! -f "$NPASS_STORE/personal/.gpg-id.sig" ]
	run "$NPASS" sign personal
	[ "$status" -eq 0 ]
	[ -f "$NPASS_STORE/personal/.gpg-id.sig" ]
}

@test "adulterar .gpg-id de uma identidade assinada faz TODA escrita falhar (nao recifra silenciosamente para destinatario trocado)" {
	"$NPASS" init --sign personal "$FPR2"
	printf 'a\na\n' | "$NPASS" insert personal x/y
	# ataque simulado: troca o destinatario para uma chave do atacante,
	# sem re-assinar (o atacante nao tem a chave privada original).
	# Testado contra uma escrita (insert), que e onde .gpg-id e lido -
	# show/decrypt usa a chave privada e nunca olha .gpg-id.
	echo "$FPR" > "$NPASS_STORE/personal/.gpg-id"
	run bash -c "printf 'b\nb\n' | '$NPASS' insert -f personal x/z"
	[ "$status" -ne 0 ]
	[[ "$output" == *"inválida"* ]] || [[ "$output" == *"invalid"* ]]
}

@test "adulterar .gpg-id.sig (nao so o .gpg-id) tambem e detectado numa escrita" {
	"$NPASS" init --sign personal "$FPR"
	echo "lixo" >> "$NPASS_STORE/personal/.gpg-id.sig"
	run bash -c "printf 'a\na\n' | '$NPASS' insert personal x/y"
	[ "$status" -ne 0 ]
}

@test "sem adulteracao nenhuma, assinatura valida nao interfere em insert/rm/mv" {
	"$NPASS" init --sign personal "$FPR"
	"$NPASS" init --sign work "$FPR2"
	printf 'a\na\n' | "$NPASS" insert personal x/y
	run "$NPASS" mv personal x/y work x/z
	[ "$status" -eq 0 ]
	run "$NPASS" show work x/z
	[ "$output" = "a" ]
	run "$NPASS" rm -f work x/z
	[ "$status" -eq 0 ]
}
