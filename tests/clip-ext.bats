#!/usr/bin/env bats
# Extensoes de clipboard npass-wclip e npass-clip-x11: nao parseiam a entrada,
# pedem o valor ao core (`npass get`). Aqui wclip/xclip sao falsos (gravam o
# stdin num arquivo), so para ver O QUE seria copiado.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" OUT="$BATS_TEST_TMPDIR/copiado"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\ncat > "%s"\n' "$OUT" >"$MOCKBIN/wclip"
	printf '#!/bin/bash\ncat > "%s"\n' "$OUT" >"$MOCKBIN/xclip"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" DISPLAY=:0 NPASS_CLIP_TIME=1
	npass_test_install_ext npass-wclip.bash || return 1
	npass_test_install_ext npass-clip-x11.bash || return 1
	"$NPASS" init HG "$FPR" >/dev/null
	printf 'a/x\0%s\0' "$(md1_doc 'segredo' 'login: eu@x.com' 'url: https://x')" | "$NPASS" insert --batch HG >/dev/null
}

teardown() { pkill -f "sleep 1$" 2>/dev/null || true; }

@test "wclip: copia a senha por padrao, um campo e o documento inteiro" {
	run "$NPASS" wclip HG a/x
	[ "$status" -eq 0 ]
	[ "$(cat "$OUT")" = "segredo" ]
	run "$NPASS" wclip login HG a/x
	[ "$(cat "$OUT")" = "eu@x.com" ]
	run "$NPASS" wclip all HG a/x
	[ "$(cat "$OUT")" = "$(md1_doc 'segredo' 'login: eu@x.com' 'url: https://x')" ]
}

@test "clip-x11: copia a senha por padrao, um campo e o documento inteiro" {
	run "$NPASS" clip-x11 HG a/x
	[ "$status" -eq 0 ]
	sleep 0.3
	[ "$(cat "$OUT")" = "segredo" ]
	run "$NPASS" clip-x11 url HG a/x
	sleep 0.3
	[ "$(cat "$OUT")" = "https://x" ]
}

@test "wclip e clip-x11: campo inexistente e entrada fora de md1 falham com a mensagem do core" {
	run "$NPASS" wclip telefone HG a/x
	[ "$status" -ne 0 ]
	[[ "$output" == *"login"* ]]
	npass_test_raw HG a/velha 'senha-velha'
	for c in wclip clip-x11; do
		run "$NPASS" "$c" HG a/velha
		[ "$status" -ne 0 ]
		[[ "$output" == *"não está no formato md1"* ]]
	done
	[ ! -s "$OUT" ] || [ "$(cat "$OUT")" != "senha-velha" ]
}

@test "wclip e clip-x11: argumentos invalidos mostram uso e nada e copiado" {
	run "$NPASS" wclip HG
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso:"* ]]
	run "$NPASS" clip-x11 HG
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}
