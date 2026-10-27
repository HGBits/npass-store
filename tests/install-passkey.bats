#!/usr/bin/env bats
# install.sh + npass-passkey: o helper nativo (Rust) so e compilado, instalado e selado
# quando a extensao e escolhida. O cargo e de mentira (registra a chamada e produz um
# "helper"); a origem das extensoes e uma copia do repositorio npass_extensions com so
# npass-import e npass-passkey (as respostas por posicao nao dependem do resto).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export NPASS_HELPERS_DIR="$BATS_TEST_TMPDIR/helpers"
	export NPASS_PASSKEY_GIT=0 NPASS_ENABLE_EXTENSIONS=1
	unset NPASS_GPG NPASS_BIN NPASS_EXTENSIONS_REPO
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true GIT_TERMINAL_PROMPT=0
	npass_test_ext_src npass-import npass-passkey || return 1
	[ -f "$NPASS_EXTENSIONS_SRC/passkey/Cargo.toml" ] || skip "passkey/Cargo.toml ausente na origem das extensoes"
	"$NPASS" init pessoal "$FPR" >/dev/null
}

pk() { "$NPASS" passkey "$@"; }

# cargo de mentira no PATH: registra a chamada e (se pedido) produz o helper.
fake_cargo() {
	mkdir -p "$BATS_TEST_TMPDIR/fakebin"
	cat >"$BATS_TEST_TMPDIR/fakebin/cargo" <<EOS
#!/bin/sh
echo "\$*" >>"$BATS_TEST_TMPDIR/cargo.log"
[ "$1" = fail ] && exit 1
case "\$*" in *--locked*) ;; *) exit 3 ;; esac
[ -n "\$FAKE_CARGO_FAIL" ] && exit 1
mkdir -p "$NPASS_EXTENSIONS_SRC/passkey/target/release"
printf '#!/bin/sh\necho helper-novo\n' >"$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"
chmod 755 "$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"
EOS
	chmod +x "$BATS_TEST_TMPDIR/fakebin/cargo"
}

# respostas: ver extensões, e uma por candidata na ordem do glob
# (aqui a origem so tem npass-import e npass-passkey, nessa ordem)
run_install() {
	local answers="$1"
	PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" bash -c "printf '$answers' | '$PROJECT_DIR/install.sh' --prefix='$BATS_TEST_TMPDIR/prefix' --extensions --sign-key='$FPR'"
}

@test "instalar outras extensões NÃO executa o cargo" {
	fake_cargo
	run run_install 's\ns\nn\n'   # só npass-import
	[ "$status" -eq 0 ]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-import" ]
	[ ! -e "$BATS_TEST_TMPDIR/cargo.log" ]
	[ ! -e "$NPASS_HELPERS_DIR/npass-passkeyd" ]
}

@test "escolher npass-passkey compila o código atual, instala, assina e sela o helper" {
	fake_cargo
	rm -rf "$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"
	# um binário velho largado em bin/ jamais é usado
	mkdir -p "$PROJECT_DIR/bin" && printf 'VELHO' >"$PROJECT_DIR/bin/npass-passkeyd"
	run run_install 's\nn\ns\n'
	[ "$status" -eq 0 ]
	grep -q -- "--release --locked --manifest-path $NPASS_EXTENSIONS_SRC/passkey/Cargo.toml" "$BATS_TEST_TMPDIR/cargo.log"
	[ -f "$NPASS_EXTENSIONS_DIR/npass-passkey.sig" ]
	[ -x "$NPASS_HELPERS_DIR/npass-passkeyd" ]
	[ -f "$NPASS_HELPERS_DIR/npass-passkeyd.sig" ]
	[ -f "$NPASS_HELPERS_DIR/npass-passkeyd.stamp.sig" ]
	run "$NPASS_HELPERS_DIR/npass-passkeyd"
	[ "$output" = "helper-novo" ]
	[ ! -e "$PROJECT_DIR/bin/npass-passkeyd" ] || [ "$(cat "$PROJECT_DIR/bin/npass-passkeyd")" != VELHO ]
	# e o ciclo fecha: serve aceita o que o instalador selou
	run pk serve pessoal
	[ "$output" = "helper-novo" ] || [ "$output" = "helper-rodou: --id pessoal" ] || [[ "$output" == *helper-novo* ]]
	rm -rf "$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"
}

@test "se o cargo falhar, a extensão não fica instalada e nenhum binário velho é aproveitado" {
	fake_cargo
	mkdir -p "$NPASS_EXTENSIONS_SRC/passkey/target/release"
	printf 'VELHO' >"$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"; chmod 755 "$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd"
	export FAKE_CARGO_FAIL=1
	rm -f "$NPASS_EXTENSIONS_DIR/npass-passkey" "$NPASS_EXTENSIONS_DIR/npass-passkey.sig"
	run run_install 's\nn\ns\n'
	[ "$status" -eq 0 ]
	[[ "$output" == *"compilação"*"falhou"* ]]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-passkey" ]
	[ ! -e "$NPASS_HELPERS_DIR/npass-passkeyd" ]
	[ ! -e "$NPASS_EXTENSIONS_SRC/passkey/target/release/npass-passkeyd" ]
}
