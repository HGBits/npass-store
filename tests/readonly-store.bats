#!/usr/bin/env bats
# Leitura com o store somente leitura: `get` e `otp` (TOTP) so leem, e o que
# nao pode ser lido sem escrever (HOTP grava o contador) falha sem imprimir
# o codigo. Quem le o store por outro UID (um daemon com bind-mount RO da
# identidade) depende disso. Observado em lib/03-store.bash (cmd_show),
# lib/02-identity.bash (mapa) e lib/05-otp.bash.
#
# chmod nao restringe o root: como root os testes sao pulados.

setup() {
	[ "$(id -u)" -ne 0 ] || skip "root ignora permissoes de arquivo"
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v oathtool >/dev/null || skip "oathtool (oath-toolkit) nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	export TEST_SECRET_B32="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	"$NPASS" init HG "$FPR" >/dev/null
	local totp hotp
	totp=$'<!-- npass:md1 -->\n## Senha\nsegredo\n\n## Campos\n- login: ana\n- email-alias: a@x.com\n\n## OTP\notpauth://totp/t?secret='"$TEST_SECRET_B32"
	hotp=$'<!-- npass:md1 -->\n## Senha\nsegredo2\n\n## OTP\notpauth://hotp/t?secret='"$TEST_SECRET_B32"'&counter=0'
	printf '%s\0%s\0%s\0%s\0' a/totp "$totp" a/hotp "$hotp" | "$NPASS" insert --batch HG >/dev/null
	# sem repositorio Git na raiz: ler nao pode depender dele
	rm -rf "$NPASS_STORE/.git" "$NPASS_STORE/.gitignore"
	snap() { find "$NPASS_STORE" -printf '%p %T@ %s %m\n' | sort; }
	snap >"$BATS_TEST_TMPDIR/antes"
	chmod -R a-w "$NPASS_STORE"
}

teardown() { chmod -R u+w "$NPASS_STORE" 2>/dev/null || true; }

@test "store somente leitura: get (senha e campo) e otp TOTP funcionam e nada no store muda" {
	[ "$("$NPASS" get HG a/totp)" = "segredo" ]
	[ "$("$NPASS" get login HG a/totp)" = "ana" ]
	[ "$("$NPASS" get --exact email-alias HG a/totp)" = "a@x.com" ]
	run "$NPASS" otp HG a/totp
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]{6}$ ]]
	chmod -R u+w "$NPASS_STORE"
	snap >"$BATS_TEST_TMPDIR/depois"
	# o chmod acima so troca o modo; compara tudo menos o modo
	diff <(cut -d' ' -f1-3 "$BATS_TEST_TMPDIR/antes") <(cut -d' ' -f1-3 "$BATS_TEST_TMPDIR/depois")
	[ ! -e "$NPASS_STORE/.git" ]
}

@test "store somente leitura: otp HOTP falha sem imprimir o codigo e sem tocar no store" {
	local out st=0
	out="$("$NPASS" otp HG a/hotp 2>/dev/null)" || st=$?
	[ "$st" -ne 0 ]
	[ -z "$out" ]
	chmod -R u+w "$NPASS_STORE"
	snap >"$BATS_TEST_TMPDIR/depois"
	diff <(cut -d' ' -f1-3 "$BATS_TEST_TMPDIR/antes") <(cut -d' ' -f1-3 "$BATS_TEST_TMPDIR/depois")
}
