#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	mkdir -p "$NPASS_STORE"
	"$NPASS" init personal "$FPR" >/dev/null
}

@test "sem NPASS_LANG definido, mensagens saem em portugues (padrao)" {
	run "$NPASS" show personal naoexiste
	[ "$status" -ne 0 ]
	[[ "$output" == *"não encontrado"* ]]
}

@test "NPASS_LANG=en muda a mensagem de erro para ingles" {
	NPASS_LANG=en run "$NPASS" show personal naoexiste
	[ "$status" -ne 0 ]
	[[ "$output" == *"not found"* ]]
	[[ "$output" != *"não encontrado"* ]]
}

@test "NPASS_LANG=en muda a confirmacao de sucesso do insert" {
	printf 'x\nx\n' | NPASS_LANG=en "$NPASS" insert personal test/x
	run bash -c "printf 'y\nnovosecreto\nnovosecreto\n' | NPASS_LANG=en '$NPASS' insert personal test/x"
	[[ "$output" == *"saved."* ]]
}

@test "NPASS_LANG=pt-BR (ou qualquer coisa que nao comece com en) cai no portugues" {
	NPASS_LANG=pt-BR run "$NPASS" show personal naoexiste
	[[ "$output" == *"não encontrado"* ]]
}

@test "uma chave de mensagem inexistente nao quebra npass_t (cai na propria chave)" {
	source <(sed -n '/^npass_t()/,/^}/p' "$NPASS")
	declare -gA NPASS_MSG_PT=()
	declare -gA NPASS_MSG_EN=()
	run npass_t chave_que_nao_existe
	[ "$status" -eq 0 ]
	[ "$output" = "chave_que_nao_existe" ]
}
