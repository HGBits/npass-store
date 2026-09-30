#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v oathtool >/dev/null || skip "oathtool (oath-toolkit) nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	mkdir -p "$NPASS_STORE"
	# secret de teste RFC 4226/6238: ASCII "12345678901234567890" em base32
	export TEST_SECRET_B32="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	"$NPASS" init personal "$FPR"
}

@test "hotp com counter=0 na URI gera o codigo do RFC 4226 para counter=1 (287082) - semantica herdada: contador armazenado = ultimo consumido" {
	local uri="otpauth://hotp/test?secret=${TEST_SECRET_B32}&counter=0"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/hotp
	run "$NPASS" otp personal aws/hotp
	[ "$status" -eq 0 ]
	[ "$output" = "287082" ]
}

@test "hotp incrementa o counter apos gerar (chamadas sucessivas -> 287082, depois 359152)" {
	local uri="otpauth://hotp/test?secret=${TEST_SECRET_B32}&counter=0"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/hotp
	run "$NPASS" otp personal aws/hotp
	[ "$output" = "287082" ]
	run "$NPASS" otp personal aws/hotp
	[ "$output" = "359152" ]
}

@test "URI HOTP armazenada permanece bem formada apos incrementar (regressao patsub_replacement/bash 5.2 com &)" {
	local uri="otpauth://hotp/test?secret=${TEST_SECRET_B32}&counter=0"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/hotp
	"$NPASS" otp personal aws/hotp >/dev/null
	run "$NPASS" otp uri personal aws/hotp
	[ "$status" -eq 0 ]
	[[ "$output" == "otpauth://hotp/test?secret=${TEST_SECRET_B32}&counter=1" ]]
	# nunca deve conter "counter=Ncounter=M" (corrupção classica do bug)
	[[ "$output" != *"counter="*"counter="* ]]
}

@test "totp gera 6 digitos numericos" {
	local uri="otpauth://totp/test?secret=${TEST_SECRET_B32}"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/totp
	run "$NPASS" otp personal aws/totp
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "otp compartilha o mesmo blob logico que a senha (linha 1 = senha, otpauth:// = OTP)" {
	printf 'minhasenha\nminhasenha\n' | "$NPASS" insert personal work/aws
	local uri="otpauth://totp/test?secret=${TEST_SECRET_B32}"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal work/aws
	run "$NPASS" show personal work/aws
	[[ "$output" == *"minhasenha"* ]]
	[[ "$output" == *"otpauth://"* ]]
	run "$NPASS" otp personal work/aws
	[[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "otp uri mostra a URI armazenada" {
	local uri="otpauth://totp/test?secret=${TEST_SECRET_B32}"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/totp
	run "$NPASS" otp uri personal aws/totp
	[ "$status" -eq 0 ]
	[[ "$output" == "$uri" ]]
}

@test "otp validate aceita URI valida e rejeita invalida" {
	run "$NPASS" otp validate "otpauth://totp/test?secret=${TEST_SECRET_B32}"
	[ "$status" -eq 0 ]
	run "$NPASS" otp validate "not-a-uri"
	[ "$status" -ne 0 ]
}

@test "npass_version_ge compara versoes dotted corretamente (regressao do bug sort -n)" {
	# Isola a funcao num subshell fonte-avel a partir do binario construido
	source <(sed -n '/^npass_version_ge()/,/^}/p' "$NPASS")
	run npass_version_ge "2.6.11" "2.6.5"
	[ "$status" -eq 0 ]
	run npass_version_ge "2.6.5" "2.6.11"
	[ "$status" -ne 0 ]
	run npass_version_ge "2.6.5" "2.6.5"
	[ "$status" -eq 0 ]
	run npass_version_ge "10.0.0" "2.6.5"
	[ "$status" -eq 0 ]
}

@test "o secret OTP nunca aparece em argv de processo algum durante a geracao (stdin only)" {
	# Sobe a geracao em background, poll /proc/*/cmdline enquanto roda,
	# e falha o teste se o secret aparecer em QUALQUER cmdline do sistema.
	local uri="otpauth://totp/test?secret=${TEST_SECRET_B32}"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal aws/totp

	(
		for _ in $(seq 1 200); do
			for f in /proc/[0-9]*/cmdline; do
				[ -r "$f" ] || continue
				if tr '\0' ' ' <"$f" 2>/dev/null | grep -q "$TEST_SECRET_B32"; then
					echo "VAZAMENTO: $f"
				fi
			done
		done
	) > "$BATS_TEST_TMPDIR/leak_scan.log" &
	local scanner=$!

	"$NPASS" otp personal aws/totp >/dev/null
	wait "$scanner" 2>/dev/null || true

	run cat "$BATS_TEST_TMPDIR/leak_scan.log"
	[ -z "$output" ]
}
