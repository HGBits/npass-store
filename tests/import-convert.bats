#!/usr/bin/env bats
# Conversao do corpo de um store PASS para md1 no import (pass_body_to_md1) e a
# verificacao que protege cada entrada importada (verify_conversion). O npass nao
# le nem migra o formato antigo: so o import de pass/pass-secrets converte, porque
# o corpo de um .gpg do pass e texto puro (linha 1 = senha, depois "chave: valor").
#
# Em duas camadas: (1) o conversor puro, chamado direto em Python; (2) o caminho
# real `npass import pass`, lido de volta pelo parser BASH do core (get/show), para
# garantir que os dois parsers concordam.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v python3 >/dev/null || skip "python3 nao instalado"
	export PYIMP="$BATS_TEST_DIRNAME/../extensions/npass-import"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export NPASS_ENABLE_EXTENSIONS=1
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	npass_test_install_ext npass-import || return 1
	"$NPASS" init HG "$FPR" >/dev/null
}

# py_conv CORPO -> o documento md1; py_lost CORPO -> quantas linhas 'chave: valor' ficaram nas notas
_py() {
	python3 - "$1" "$2" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("imp", os.environ["PYIMP"])
spec = importlib.util.spec_from_loader("imp", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
doc, lost = m.pass_body_to_md1(sys.argv[2])
sys.stdout.write(doc if sys.argv[1] == "doc" else str(lost))
PY
}
py_conv() { _py doc "$1"; }
py_lost() { _py lost "$1"; }

# mkpass DIR REL CORPO: cria DIR/REL.gpg cifrado para a chave de teste
mkpass() {
	mkdir -p "$(dirname "$1/$2")"
	[ -f "$1/.gpg-id" ] || printf '%s\n' "$FPR" >"$1/.gpg-id"
	printf '%s' "$3" | gpg --batch --yes --quiet --trust-model always -r "$FPR" -e -o "$1/$2.gpg"
}

# --- o conversor (regras) --------------------------------------------------------------------------

@test "so senha, e campos + notas" {
	[ "$(py_conv 'hunter2')" = "$(md1_doc hunter2)" ]
	[ "$(py_conv $'S3nha\nlogin: eu@x.com\nurl: https://x\n\nnota 1\nnota 2')" = "$(md1_doc S3nha 'login: eu@x.com' 'url: https://x')"$'\n\n## Notas\nnota 1\nnota 2' ]
}

@test "entrada so de OTP (linha 1 e otpauth://): senha vazia e a secao OTP" {
	local uri='otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'
	[ "$(py_conv "$uri")" = $'<!-- npass:md1 -->\n## Senha\n\n\n## OTP\n'"$uri" ]
}

@test "linhas otpauth:// soltas nas notas sobem para a secao OTP; nada e perdido" {
	[ "$(py_conv $'pw\n\numa nota\notpauth://totp/z?secret=QQQQ\noutra nota')" = $'<!-- npass:md1 -->\n## Senha\npw\n\n## OTP\notpauth://totp/z?secret=QQQQ\n\n## Notas\numa nota\noutra nota' ]
}

@test "etiquetas '# nome-real:' / '# email-alias:' (gravadas pelo import do pass-secrets) viram campos" {
	[ "$(py_conv $'pw\nlogin: u\n\nnota\n# nome-real: Natty Corp\n# email-alias: a@x.com')" = "$(md1_doc pw 'login: u' 'nome-real: Natty Corp' 'email-alias: a@x.com')"$'\n\n## Notas\nnota' ]
}

@test "campo '# chave: valor' dentro do bloco de campos vira campo; texto livre vai para as notas" {
	[ "$(py_conv $'pw\nlogin: u\n# extra: v\nlivre sem branco\noutra')" = $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- login: u\n- extra: v\n\n## Notas\nlivre sem branco\noutra' ]
}

@test "senha que parece cabecalho/campo e notas que parecem cabecalho sao preservadas" {
	[ "$(py_conv $'## Campos\nlogin: u\n\n## Notas\n- falso: campo')" = $'<!-- npass:md1 -->\n## Senha\n## Campos\n\n## Campos\n- login: u\n\n## Notas\n## Notas\n- falso: campo' ]
}

@test "conta as linhas 'chave: valor' que ficaram nas notas (nao viram campo)" {
	[ "$(py_lost $'pw\n\nLembrete: ligar amanha')" = "1" ]
	[ "$(py_lost $'pw\nlogin: u\n\nsem chave aqui')" = "0" ]
}

@test "unicode e senha com espacos nas pontas sobrevivem" {
	[ "$(py_conv $'  sénha com espaço  \nnome: João')" = "$(md1_doc '  sénha com espaço  ' 'nome: João')" ]
}

# --- o caminho real: import pass, lido pelo parser bash do core ---------------------------------------

@test "import pass: o corpo de cada .gpg entra em md1 (campos, OTP e notas) e o core le" {
	local d="$BATS_TEST_TMPDIR/ps"
	mkpass "$d" mail/gmail $'S3nha\nlogin: eu@x.com\nurl: https://x\notpauth://totp/x?secret=JBSWY3DPEHPK3PXP\n\nnota livre\n'
	run "$NPASS" import pass HG "$d"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG mail/gmail
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\nS3nha\n\n## Campos\n- login: eu@x.com\n- url: https://x\n\n## OTP\notpauth://totp/x?secret=JBSWY3DPEHPK3PXP\n\n## Notas\nnota livre' ]
	[ "$("$NPASS" get HG mail/gmail)" = "S3nha" ]
	[ "$("$NPASS" get login HG mail/gmail)" = "eu@x.com" ]
}

@test "os dois parsers concordam: show do import == conversor em Python, e get le senha e campos" {
	local d="$BATS_TEST_TMPDIR/ps" i=0 body
	local -a bodies=(
		'hunter2'
		$'S3nha\nlogin: eu@x.com\nurl: https://x\n\nnota 1\nnota 2'
		$'pw\n\numa nota\notpauth://totp/z?secret=QQQQ\noutra nota'
		$'pw\nlogin: u\n\nnota\n# nome-real: Natty Corp\n# email-alias: a@x.com'
		$'pw\nlogin: u\n# extra: v\nlivre sem branco\noutra'
		$'## Campos\nlogin: u\n\n## Notas\n- falso: campo'
		$'  sénha com espaço  \nnome: João'
		$'# pw\nlogin: x'
	)
	for body in "${bodies[@]}"; do
		mkpass "$d" "lote/$i" "$body"
		i=$((i + 1))
	done
	run "$NPASS" import pass HG "$d"
	[ "$status" -eq 0 ]
	i=0
	for body in "${bodies[@]}"; do
		[ "$("$NPASS" show HG "lote/$i")" = "$(py_conv "$body")" ]
		local first="${body%%$'\n'*}"
		[ "$("$NPASS" get HG "lote/$i")" = "$first" ]
		i=$((i + 1))
	done
	[ "$("$NPASS" get nome-real HG lote/3)" = "Natty Corp" ]
	[ "$("$NPASS" get extra HG lote/4)" = "v" ]
	[ "$("$NPASS" get nome HG lote/6)" = "João" ]
}

@test "import pass avisa (com --verbose) as linhas chave: valor que ficaram nas notas" {
	local d="$BATS_TEST_TMPDIR/ps"
	mkpass "$d" a/x $'pw\n\nLembrete: ligar amanha\n'
	run "$NPASS" import pass --verbose HG "$d"
	[ "$status" -eq 0 ]
	[[ "$output" == *"a/x"*"ficaram nas notas"* ]]
	run "$NPASS" get Lembrete HG a/x
	[ "$status" -ne 0 ]
}

@test "import pass: conversao que NAO passa na verificacao e ignorada, avisada e conta como falha" {
	local d="$BATS_TEST_TMPDIR/ps"
	mkpass "$d" a/boa $'pw-boa\nlogin: u'
	mkpass "$d" a/ruim $'pw-ruim\nlogin: u\n\nnota importante'
	# conversor corrompido so para a entrada "ruim": descarta a nota (a verificacao tem que pegar)
	run env NPASS_BIN="$NPASS" PYIMP="$PYIMP" python3 - "$d" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("imp", os.environ["PYIMP"])
spec = importlib.util.spec_from_loader("imp", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
orig = m.pass_body_to_md1
def corrompido(body):
    doc, lost = orig(body)
    if body.startswith("pw-ruim"):
        doc = doc.split("\n\n## Notas")[0]   # perde a nota
    return doc, lost
m.pass_body_to_md1 = corrompido
sys.exit(m.main(["pass", "HG", sys.argv[1]]))
PY
	[ "$status" -ne 0 ]
	[[ "$output" == *"a/ruim"*"não passou na verificação"* ]]
	run "$NPASS" ls --flat HG
	[[ "$output" == *"a/boa"* ]]
	[[ "$output" != *"a/ruim"* ]]
	[ "$("$NPASS" get HG a/boa)" = "pw-boa" ]
}

# --- a verificacao e a rede de seguranca: ela precisa reprovar conversao errada --------------------------

# py_verify CORPO DOC -> exit 0 se verify_conversion(CORPO, DOC) aprova
py_verify() {
	python3 - "$1" "$2" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("imp", os.environ["PYIMP"])
spec = importlib.util.spec_from_loader("imp", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.exit(0 if m.verify_conversion(sys.argv[1], sys.argv[2]) else 1)
PY
}

@test "verify_conversion aprova a conversao correta e reprova as 4 corrupcoes classicas" {
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
	py_verify $'pw\nkey : v\n# nome-real: N' $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- key: v\n- nome-real: N'
	run py_verify $'pw\nkey : v' $'<!-- npass:md1 -->\n## Senha\npw\n\n## Campos\n- key: w'
	[ "$status" -ne 0 ]
}

# --- o npass nao migra mais o formato antigo -------------------------------------------------------------

@test "npass-legacy deixou de existir: formato desconhecido, fora do --list, e o migrate antigo nao o cita" {
	run "$NPASS" import npass-legacy HG
	[ "$status" -ne 0 ]
	[[ "$output" != *"Traceback"* ]]
	run "$NPASS" import --list
	[ "$status" -eq 0 ]
	[[ "$output" != *"npass-legacy"* ]]
	[[ "$output" == *"pass-secrets"* ]]
	run "$NPASS" migrate
	[ "$status" -ne 0 ]
	[[ "$output" == *"npass import pass"* ]]
	[[ "$output" != *"npass-legacy"* ]]
}

@test "nenhuma referencia ao fluxo removido sobra no codigo, nas extensoes, no instalador e nas docs" {
	local root="$BATS_TEST_DIRNAME/.."
	run grep -rIl --exclude-dir=__pycache__ --exclude-dir=target --exclude-dir=.git -e 'npass-legacy' -e 'migrate_legacy_store' -e 'legacy_to_md1' -e 'erro_formato_antigo' \
		"$root/lib" "$root/extensions" "$root/README.md" "$root/man" "$root/AGENTS.md" "$root/install.sh" "$root/packaging"
	[ -z "$output" ]
}
