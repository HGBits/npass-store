#!/usr/bin/env bats
# npass import npass-legacy ID: converte uma identidade do formato antigo (texto
# puro, linha 1 = senha) para md1, no proprio store. Cobre o conversor, a
# verificacao, a idempotencia, o --dry-run e a convivencia com anexos de backup.
# Entradas legadas sao semeadas com npass_test_legacy (insert so grava md1).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v python3 >/dev/null || skip "python3 nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export NPASS_ENABLE_EXTENSIONS=1
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	npass_test_install_ext npass-import || return 1
	"$NPASS" init HG "$FPR" >/dev/null
}

# --- conversao -------------------------------------------------------------------------------------

@test "converte so senha, campos+notas e entrada so de OTP" {
	local uri='otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'
	npass_test_legacy HG a/so 'hunter2'
	npass_test_legacy HG a/completa $'S3nha\nlogin: eu@x.com\nurl: https://x\n\nnota 1\nnota 2'
	npass_test_legacy HG a/otp "$uri"
	run "$NPASS" import npass-legacy HG
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 convertida(s)"* ]]
	run "$NPASS" show HG a/so
	[ "$output" = "$(md1_doc hunter2)" ]
	run "$NPASS" show HG a/completa
	[ "$output" = "$(md1_doc S3nha 'login: eu@x.com' 'url: https://x')"$'\n\n## Notas\nnota 1\nnota 2' ]
	run "$NPASS" show HG a/otp
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\n\n\n## OTP\n'"$uri" ]
}

@test "depois de convertida a entrada e lida normalmente por get/clip/otp" {
	npass_test_legacy HG a/x $'segredo\nlogin: eu\notpauth://totp/x?secret=JBSWY3DPEHPK3PXP'
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$("$NPASS" get HG a/x)" = "segredo" ]
	[ "$("$NPASS" get login HG a/x)" = "eu" ]
	run "$NPASS" otp uri HG a/x
	[ "$status" -eq 0 ]
	[[ "$output" == *"JBSWY3DPEHPK3PXP"* ]]
}

@test "linhas otpauth:// soltas nas notas sobem para a secao OTP; nada e perdido" {
	npass_test_legacy HG a/x $'pw\n\numa nota\notpauth://totp/z?secret=QQQQ\noutra nota'
	"$NPASS" import npass-legacy HG >/dev/null
	run "$NPASS" show HG a/x
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\npw\n\n## OTP\notpauth://totp/z?secret=QQQQ\n\n## Notas\numa nota\noutra nota' ]
}

@test "etiquetas '# nome-real:' / '# email-alias:' (import antigo do pass-secrets) viram campos" {
	npass_test_legacy HG a/x $'pw\nlogin: u\n\nnota\n# nome-real: Natty Corp\n# email-alias: a@x.com'
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$("$NPASS" get nome-real HG a/x)" = "Natty Corp" ]
	[ "$("$NPASS" get email-alias HG a/x)" = "a@x.com" ]
	run "$NPASS" show HG a/x
	[[ "$output" == *$'\n\n## Notas\nnota' ]]
}

@test "campo '# chave: valor' dentro do bloco de campos vira campo; texto livre vai para as notas" {
	npass_test_legacy HG a/x $'pw\nlogin: u\n# extra: v\nlivre sem branco\noutra'
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$("$NPASS" get extra HG a/x)" = "v" ]
	run "$NPASS" show HG a/x
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- login: u\n- extra: v\n\n## Notas\nlivre sem branco\noutra' ]
}

@test "senha que parece cabecalho ou campo, e notas que parecem cabecalho, sao preservadas" {
	npass_test_legacy HG a/x $'## Campos\nlogin: u\n\n## Notas\n- falso: campo'
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$("$NPASS" get HG a/x)" = "## Campos" ]
	[ "$("$NPASS" get login HG a/x)" = "u" ]
	run "$NPASS" show HG a/x
	[[ "$output" == *$'\n\n## Notas\n## Notas\n- falso: campo' ]]
}

@test "avisa quando uma linha 'chave: valor' ficou nas notas (nao vira campo)" {
	npass_test_legacy HG a/x $'pw\n\nLembrete: ligar amanha'
	run "$NPASS" import npass-legacy HG
	[ "$status" -eq 0 ]
	[[ "$output" == *"a/x"*"ficaram nas notas"* ]]
	run "$NPASS" get Lembrete HG a/x
	[ "$status" -ne 0 ]
}

@test "unicode e senha com espacos nas pontas sobrevivem" {
	npass_test_legacy HG a/x $'  sénha com espaço  \nnome: João'
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$("$NPASS" get HG a/x)" = "  sénha com espaço  " ]
	[ "$("$NPASS" get nome HG a/x)" = "João" ]
}

# --- idempotencia, anexos, dry-run -------------------------------------------------------------

@test "idempotente: a 2a execucao nao converte nada e nao mexe nas entradas md1" {
	npass_test_legacy HG a/velha 'senha-velha'
	printf 'nova\nnova\n' | "$NPASS" insert HG a/nova >/dev/null
	run "$NPASS" import npass-legacy HG
	[[ "$output" == *"1 convertida(s), 1 já em md1"* ]]
	local antes; antes="$(git -C "$NPASS_STORE" rev-parse HEAD)"
	run "$NPASS" import npass-legacy HG
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nenhuma entrada"* ]]
	[ "$(git -C "$NPASS_STORE" rev-parse HEAD)" = "$antes" ]
}

@test "anexos de backup nao sao tocados nem contados como entrada" {
	printf 'x\nx\n' | "$NPASS" insert HG a/x >/dev/null
	printf 'b1\nb1\n' | "$NPASS" backup -n 1 HG a/x >/dev/null
	npass_test_legacy HG a/velha 'senha-velha'
	local dados; dados="$("$NPASS" show HG a/x/Backup-x.dados.md)"
	run "$NPASS" import npass-legacy HG
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 anexo(s) de backup"* ]]
	[ "$("$NPASS" show HG a/x/Backup-x.dados.md)" = "$dados" ]
}

@test "--dry-run lista o que seria convertido e nao grava nada" {
	npass_test_legacy HG a/velha 'senha-velha'
	local antes; antes="$(git -C "$NPASS_STORE" rev-parse HEAD)"
	run "$NPASS" import npass-legacy HG --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"~ a/velha"* ]]
	[ "$("$NPASS" show HG a/velha)" = "senha-velha" ]
	[ "$(git -C "$NPASS_STORE" rev-parse HEAD)" = "$antes" ]
}

@test "faz UM commit generico e o formato antigo continua no historico do git" {
	npass_test_legacy HG a/um 'um'
	npass_test_legacy HG a/dois 'dois'
	local antes; antes="$(git -C "$NPASS_STORE" rev-list --count HEAD)"
	"$NPASS" import npass-legacy HG >/dev/null
	[ "$(( $(git -C "$NPASS_STORE" rev-list --count HEAD) - antes ))" -eq 1 ]
	run git -C "$NPASS_STORE" log -1 --format=%s
	[[ "$output" != *"a/um"* ]]
}

@test "conversao em lote vira md1 valido para o parser do core (todas as entradas legiveis)" {
	local i
	for i in 1 2 3 4 5; do
		npass_test_legacy HG "lote/$i" $'senha'"$i"$'\nlogin: u'"$i"$'\n\nnota '"$i"
	done
	"$NPASS" import npass-legacy HG >/dev/null
	for i in 1 2 3 4 5; do
		[ "$("$NPASS" get HG "lote/$i")" = "senha$i" ]
		[ "$("$NPASS" get login HG "lote/$i")" = "u$i" ]
	done
}

# --- a verificacao e a rede de seguranca: ela precisa reprovar conversao errada --------------------------

# py_verify CORPO DOC -> exit 0 se verify_conversion(CORPO, DOC) aprova
py_verify() {
	python3 - "$@" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("imp", sys.argv[0] if False else "extensions/npass-import")
spec = importlib.util.spec_from_loader("imp", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.exit(0 if m.verify_conversion(sys.argv[1], sys.argv[2]) else 1)
PY
}

@test "verify_conversion aprova a conversao correta e reprova as 4 corrupcoes classicas" {
	cd "$PROJECT_DIR" 2>/dev/null || cd "$BATS_TEST_DIRNAME/.."
	local body=$'pw\nlogin: eu\notpauth://totp/x?secret=ABC\n\nnota 1\nnota 2'
	local ok=$'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- login: eu\n\n## OTP\notpauth://totp/x?secret=ABC\n\n## Notas\nnota 1\nnota 2'
	py_verify "$body" "$ok"
	# 1) nota perdida
	run py_verify "$body" "${ok%$'\nnota 2'}"
	[ "$status" -ne 0 ]
	# 2) senha alterada
	[ "${ok/$'\npw\n'/$'\nPW\n'}" != "$ok" ]
	run py_verify "$body" "${ok/$'\npw\n'/$'\nPW\n'}"
	[ "$status" -ne 0 ]
	# 3) OTP perdido
	run py_verify "$body" $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- login: eu\n\n## Notas\nnota 1\nnota 2'
	[ "$status" -ne 0 ]
	# 4) linha duplicada
	run py_verify "$body" "$ok"$'\nnota 2'
	[ "$status" -ne 0 ]
	# campo com outro valor
	run py_verify "$body" "${ok/login: eu/login: outro}"
	[ "$status" -ne 0 ]
	# nao e md1
	run py_verify "$body" "$body"
	[ "$status" -ne 0 ]
}

@test "verify_conversion tolera 'chave : valor' e '# etiqueta:' (normalizados), sem aprovar o que muda de valor" {
	cd "$BATS_TEST_DIRNAME/.."
	py_verify $'pw\nkey : v\n# nome-real: N' $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- key: v\n- nome-real: N'
	run py_verify $'pw\nkey : v' $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- key: w'
	[ "$status" -ne 0 ]
}

# --- uso -------------------------------------------------------------------------------------------

@test "npass-legacy exige so a identidade; identidade inexistente falha" {
	run "$NPASS" import npass-legacy
	[ "$status" -ne 0 ]
	run "$NPASS" import npass-legacy HG extra
	[ "$status" -ne 0 ]
	[[ "$output" == *"npass import npass-legacy ID"* ]]
	run "$NPASS" import npass-legacy NAOEXISTE
	[ "$status" -ne 0 ]
	[[ "$output" == *"identidade não encontrada: NAOEXISTE"* ]]
	[[ "$output" != *"Traceback"* ]]
	NPASS_LANG=en run "$NPASS" import npass-legacy NAOEXISTE
	[ "$status" -ne 0 ]
	[[ "$output" == *"identity not found: NAOEXISTE"* ]]
}

@test "identidade vazia: nada a converter" {
	run "$NPASS" import npass-legacy HG
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nenhuma entrada"* ]]
}

@test "import --list mostra npass-legacy e o comando migrate antigo aponta para ele" {
	run "$NPASS" import --list
	[[ "$output" == *"npass-legacy"* ]]
	run "$NPASS" migrate
	[ "$status" -ne 0 ]
	[[ "$output" == *"npass-legacy"* ]]
}

# --- imports de arvore (pass / pass-secrets) ja entram em md1 -----------------------------------------

@test "import pass: o corpo de cada .gpg entra convertido para md1 (campos, OTP e notas)" {
	local d="$BATS_TEST_TMPDIR/ps"
	mkdir -p "$d/mail" "$GNUPGHOME"
	printf '%s\n' "$FPR" >"$d/.gpg-id"
	printf 'S3nha\nlogin: eu@x.com\nurl: https://x\notpauth://totp/x?secret=JBSWY3DPEHPK3PXP\n\nnota livre\n' \
		| gpg --batch --yes --quiet --trust-model always -r "$FPR" -e -o "$d/mail/gmail.gpg"
	run "$NPASS" import pass HG "$d"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG mail/gmail
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\nS3nha\n\n## Campos\n- login: eu@x.com\n- url: https://x\n\n## OTP\notpauth://totp/x?secret=JBSWY3DPEHPK3PXP\n\n## Notas\nnota livre' ]
	[ "$("$NPASS" get login HG mail/gmail)" = "eu@x.com" ]
}
