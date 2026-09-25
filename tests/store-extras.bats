#!/usr/bin/env bats

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export FPR="1B952E15B3CC559EEEF66340AAFD46D940B7AE4E"
	mkdir -p "$NPASS_STORE"
	"$NPASS" init personal "$FPR"
}

# --- find ------------------------------------------------------------------

@test "find retorna caminhos logicos que casam o padrao" {
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	printf 'b\nb\n' | "$NPASS" insert personal email/outlook
	printf 'c\nc\n' | "$NPASS" insert personal aws/root
	run "$NPASS" find personal mail
	[ "$status" -eq 0 ]
	[[ "$output" == *"email/gmail"* ]]
	[[ "$output" == *"email/outlook"* ]]
	[[ "$output" != *"aws/root"* ]]
}

@test "find sem match retorna status de erro" {
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" find personal naoexiste123
	[ "$status" -ne 0 ]
}

# --- grep --------------------------------------------------------------------

@test "grep encontra padrao dentro do conteudo decifrado" {
	printf 'senhaUnica999\nsenhaUnica999\n' | "$NPASS" insert personal email/gmail
	printf 'outracoisa\noutracoisa\n' | "$NPASS" insert personal email/outlook
	run "$NPASS" grep personal "Unica999"
	[ "$status" -eq 0 ]
	[[ "$output" == *"email/gmail"* ]]
	[[ "$output" != *"email/outlook"* ]]
}

@test "grep sem match em nenhuma entrada retorna status de erro" {
	printf 'abc\nabc\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" grep personal "xyz_nao_existe"
	[ "$status" -ne 0 ]
}

@test "grep repassa opcoes do grep (-i para case-insensitive)" {
	printf 'MAIUSCULA\nMAIUSCULA\n' | "$NPASS" insert personal email/gmail
	run "$NPASS" grep personal -i "maiuscula"
	[ "$status" -eq 0 ]
	[[ "$output" == *"email/gmail"* ]]
}

@test "grep encontra URI OTP no conteudo (segredo continua so na URI, nao no texto)" {
	local uri="otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	printf '%s\n%s\n' "$uri" "$uri" | "$NPASS" otp insert -f personal work/aws
	run "$NPASS" grep personal "otpauth://totp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"work/aws"* ]]
}

# --- git ---------------------------------------------------------------------

@test "sem git init, operacoes normais nao falham (git e opcional)" {
	run bash -c "printf 'a\na\n' | '$NPASS' insert personal email/gmail"
	[ "$status" -eq 0 ]
	[ ! -d "$NPASS_STORE/.git" ]
}

@test "npass git init habilita repositorio dentro do store" {
	run "$NPASS" git init
	[ "$status" -eq 0 ]
	[ -d "$NPASS_STORE/.git" ]
}

@test "insert apos git init gera um commit" {
	"$NPASS" git init >/dev/null
	git -C "$NPASS_STORE" config user.email t@t.local
	git -C "$NPASS_STORE" config user.name t
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	run git -C "$NPASS_STORE" log --oneline
	[ "$status" -eq 0 ]
	[ "$(wc -l <<<"$output")" -ge 1 ]
}

@test "mensagem de commit NUNCA contem o caminho logico do segredo (so id + acao generica)" {
	"$NPASS" git init >/dev/null
	git -C "$NPASS_STORE" config user.email t@t.local
	git -C "$NPASS_STORE" config user.name t
	printf 'segredoTeste\nsegredoTeste\n' | "$NPASS" insert personal email/gmail-super-secreto
	run git -C "$NPASS_STORE" log --format=%s
	[ "$status" -eq 0 ]
	[[ "$output" != *"gmail-super-secreto"* ]]
	[[ "$output" != *"email/"* ]]
	[[ "$output" == *"insert: personal"* ]]
}

@test "nenhum arquivo em texto claro no historico do git contem o caminho logico (git log -p)" {
	"$NPASS" git init >/dev/null
	git -C "$NPASS_STORE" config user.email t@t.local
	git -C "$NPASS_STORE" config user.name t
	printf 'x\nx\n' | "$NPASS" insert personal financas/banco-privado-xyz
	run git -C "$NPASS_STORE" log -p
	[ "$status" -eq 0 ]
	[[ "$output" != *"banco-privado-xyz"* ]]
	[[ "$output" != *"financas/"* ]]
}

@test "rm apos remocao tambem commita (blob some do commit seguinte)" {
	"$NPASS" git init >/dev/null
	git -C "$NPASS_STORE" config user.email t@t.local
	git -C "$NPASS_STORE" config user.name t
	printf 'a\na\n' | "$NPASS" insert personal email/gmail
	local commits_before; commits_before="$(git -C "$NPASS_STORE" rev-list --count HEAD)"
	"$NPASS" rm -f personal email/gmail
	local commits_after; commits_after="$(git -C "$NPASS_STORE" rev-list --count HEAD)"
	[ "$commits_after" -gt "$commits_before" ]
	run git -C "$NPASS_STORE" log --format=%s -1
	[[ "$output" == *"rm: personal"* ]]
}

@test "mv entre identidades gera dois commits (mv-in no destino, mv-out na origem), sem nome logico" {
	"$NPASS" init work "$FPR"
	"$NPASS" git init >/dev/null
	git -C "$NPASS_STORE" config user.email t@t.local
	git -C "$NPASS_STORE" config user.name t
	printf 'a\na\n' | "$NPASS" insert personal email/gmail-secreto
	"$NPASS" mv personal email/gmail-secreto work aws/root-secreto
	run git -C "$NPASS_STORE" log --format=%s
	[[ "$output" == *"mv-in: work"* ]]
	[[ "$output" == *"mv-out: personal"* ]]
	[[ "$output" != *"gmail-secreto"* ]]
	[[ "$output" != *"root-secreto"* ]]
}
