#!/usr/bin/env bats
# npass show renderizado com glow (lib/16-view.bash). O glow aqui e falso: grava
# argumentos e stdin e devolve o stdin com uma marca. O que se testa e (1) QUANDO
# renderiza, (2) O QUE o glow recebe (documento de exibicao: senha em codigo, nada
# interpretado, nada em argv) e (3) o que acontece quando o glow falta ou falha.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v python3 >/dev/null || skip "python3 nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	export GLOWLOG="$BATS_TEST_TMPDIR/glowlog"
	cat >"$BATS_TEST_TMPDIR/glow" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$GLOWLOG.args"
cat >"$GLOWLOG.in"
printf '<<GLOW>>\n'
cat "$GLOWLOG.in"
EOF
	chmod +x "$BATS_TEST_TMPDIR/glow"
	export NPASS_GLOW="$BATS_TEST_TMPDIR/glow"
	unset NPASS_SHOW_RENDER NPASS_GLOW_STYLE NPASS_GLOW_WIDTH
	"$NPASS" init HG "$FPR" >/dev/null
}

put() { printf '%s\0%s\0' "$1" "$2" | "$NPASS" insert --batch -f HG >/dev/null; }

# run_tty CMD...: roda com stdout num pseudo-terminal (para -t 1 ser verdade)
run_tty() {
	python3 - "$@" <<'PY'
import os, pty, subprocess, sys
m, s = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdout=s, stdin=subprocess.DEVNULL, close_fds=True)
os.close(s)
out = b""
while True:
    try:
        d = os.read(m, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
p.wait()
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(p.returncode)
PY
}

# --- quando renderiza -----------------------------------------------------------------------------

@test "fora de terminal (pipe, script, extensao): documento CRU, o glow nem e chamado" {
	put a/x "$(md1_doc segredo 'login: eu')"
	run "$NPASS" show HG a/x
	[ "$status" -eq 0 ]
	[ "$output" = "$(md1_doc segredo 'login: eu')" ]
	[ ! -e "$GLOWLOG.in" ]
}

@test "em terminal (TTY): renderiza pelo glow" {
	put a/x "$(md1_doc segredo 'login: eu')"
	run run_tty "$NPASS" show HG a/x
	[ "$status" -eq 0 ]
	[[ "$output" == *"<<GLOW>>"* ]]
	[ -e "$GLOWLOG.in" ]
}

@test "em terminal, --raw e NPASS_SHOW_RENDER=never imprimem o cru" {
	put a/x "$(md1_doc segredo)"
	run run_tty "$NPASS" show --raw HG a/x
	[ "$output" = "$(md1_doc segredo)" ]
	NPASS_SHOW_RENDER=never run run_tty "$NPASS" show HG a/x
	[ "$output" = "$(md1_doc segredo)" ]
	[ ! -e "$GLOWLOG.in" ]
}

@test "--render e NPASS_SHOW_RENDER=always renderizam mesmo em pipe; a flag vence o ambiente" {
	put a/x "$(md1_doc segredo)"
	run "$NPASS" show --render HG a/x
	[[ "$output" == "<<GLOW>>"* ]]
	NPASS_SHOW_RENDER=always run "$NPASS" show HG a/x
	[[ "$output" == "<<GLOW>>"* ]]
	NPASS_SHOW_RENDER=never run "$NPASS" show --render HG a/x
	[[ "$output" == "<<GLOW>>"* ]]
	NPASS_SHOW_RENDER=always run "$NPASS" show --raw HG a/x
	[ "$output" = "$(md1_doc segredo)" ]
}

# --- o que o glow recebe ----------------------------------------------------------------------------

@test "documento de exibicao: titulo, secoes, senha em bloco de codigo" {
	put a/x "$(md1_doc segredo 'login: eu@x.com')"$'\n\n## Notas\numa nota'
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[ "$output" = $'# a/x\n\n## Senha\n\n```\nsegredo\n```\n\n## Campos\n\n- **login**: ` eu@x.com `\n\n## Notas\n\numa nota' ]
}

@test "senha com markdown (a*b*c_d_<e>&\\f, ## x, # y) entra LITERAL num bloco, sem escape" {
	local pw='a*b*c_d_<e>&\f ## x'
	put a/x "$(md1_doc "$pw")"
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'```\n'"$pw"$'\n```'* ]]
	put a/y "$(md1_doc '# titulo falso')"
	"$NPASS" show --render HG a/y >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'```\n# titulo falso\n```'* ]]
}

@test "senha com crases: a cerca e sempre mais longa que a maior sequencia de crases" {
	put a/x "$(md1_doc 'a```b')"
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'````\na```b\n````'* ]]
	put a/y "$(md1_doc '`')"
	"$NPASS" show --render HG a/y >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'```\n`\n```'* ]]
}

@test "senha vazia mostra (vazia); a entrada so de OTP mostra o OTP em bloco" {
	put a/x "$(md1_doc '')"$'\n\n## OTP\notpauth://totp/x?secret=ABC&issuer=Y'
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'## Senha\n\n*(vazia)*'* ]]
	[[ "$output" == *$'## OTP\n\n```\notpauth://totp/x?secret=ABC&issuer=Y\n```'* ]]
}

@test "campos: valor em span de codigo, nome escapado, URL vira autolink, vazio vira (vazio)" {
	put a/x "$(md1_doc pw 'lo*gin_x: a*b' 'url: https://x.com/a_b' 'nada:' 'cr: x`y')"
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *'- **lo\*gin\_x**: ` a*b `'* ]]
	[[ "$output" == *'- **url**: <https://x.com/a_b>'* ]]
	[[ "$output" == *'- **nada**: *(vazio)*'* ]]
	[[ "$output" == *'- **cr**: `` x`y ``'* ]]
}

@test "valor com cara de URL mas com caractere perigoso nao vira autolink" {
	put a/x "$(md1_doc pw 'url: https://x.com/<b>' 'u2: https://x.com/a)b')"
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" != *"<https://"* ]]
	[[ "$output" == *'` https://x.com/<b> `'* ]]
}

@test "as notas sao markdown de verdade: passam como estao" {
	put a/x "$(md1_doc pw)"$'\n\n## Notas\numa **nota** com [link](https://z.org)\n- item\n\n## Senha'
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *$'## Notas\n\numa **nota** com [link](https://z.org)\n- item\n\n## Senha' ]]
}

@test "o glow recebe a senha so por stdin: nada em argv; sem arquivo temporario com ela" {
	put a/x "$(md1_doc 'SenhaUnicaXYZ123')"
	"$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.args"
	[ "$output" = "-" ]
	[[ "$output" != *"SenhaUnicaXYZ123"* ]]
	run grep -rl "SenhaUnicaXYZ123" "$NPASS_STORE" "${TMPDIR:-/tmp}/npass"* 2>/dev/null
	[[ "$output" != *"SenhaUnicaXYZ123"* ]]
}

@test "NPASS_GLOW_STYLE e NPASS_GLOW_WIDTH viram -s e -w; sem eles so '-'" {
	put a/x "$(md1_doc pw)"
	NPASS_GLOW_STYLE=dark NPASS_GLOW_WIDTH=70 "$NPASS" show --render HG a/x >/dev/null
	run cat "$GLOWLOG.args"
	[ "$output" = "-s dark -w 70 -" ]
}

# --- anexos de backup ---------------------------------------------------------------------------------

@test "anexos de backup: dados com cada senha em bloco; ponteiro como lista" {
	printf 'x\nx\n' | "$NPASS" insert HG a/x >/dev/null
	printf 'b*1_\nb*1_\nb2\nb2\n' | "$NPASS" backup -n 2 HG a/x >/dev/null
	"$NPASS" show --render HG a/x/Backup-x.dados.md >/dev/null
	run cat "$GLOWLOG.in"
	[ "$output" = $'# a/x/Backup-x.dados.md\n\nEntrada: [x](npass://HG/a/x)\n\n\n## Backup 1\n\n```\nb*1_\n```\n\n## Backup 2\n\n```\nb2\n```' ]
	"$NPASS" show --render HG a/x/Backup-x.md >/dev/null
	run cat "$GLOWLOG.in"
	[[ "$output" == *'- **arquivo**: [Backup-x.dados.md](npass://HG/a/x/Backup-x.dados.md)'* ]]
	[[ "$output" == *'- **quantidade**: ` 2 `'* ]]
}

# --- quando o glow falta ou falha -----------------------------------------------------------------------

@test "sem glow: avisa e imprime o documento cru (status 0)" {
	put a/x "$(md1_doc segredo)"
	NPASS_GLOW="$BATS_TEST_TMPDIR/nao-existe" run "$NPASS" show --render HG a/x
	[ "$status" -eq 0 ]
	[[ "$output" == *"glow não encontrado"* ]]
	[[ "$output" == *"$(md1_doc segredo)"* ]]
	NPASS_GLOW="$BATS_TEST_TMPDIR/nao-existe" NPASS_LANG=en run "$NPASS" show --render HG a/x
	[[ "$output" == *"glow not found"* ]]
}

@test "glow que falha: avisa com o codigo e imprime o cru" {
	put a/x "$(md1_doc segredo)"
	printf '#!/bin/bash\ncat >/dev/null\nexit 3\n' >"$BATS_TEST_TMPDIR/ruim"
	chmod +x "$BATS_TEST_TMPDIR/ruim"
	NPASS_GLOW="$BATS_TEST_TMPDIR/ruim" run "$NPASS" show --render HG a/x
	[ "$status" -eq 0 ]
	[[ "$output" == *"o glow falhou (código 3)"* ]]
	[[ "$output" == *"$(md1_doc segredo)"* ]]
	[[ "$output" != *"<<GLOW>>"* ]]
}

# --- o que nao se renderiza ---------------------------------------------------------------------------------

@test "formato antigo ou estrutura invalida: cru, sem chamar o glow" {
	npass_test_legacy HG a/velha $'senha-velha\nlogin: x'
	run "$NPASS" show --render HG a/velha
	[ "$output" = $'senha-velha\nlogin: x' ]
	npass_test_legacy HG a/ruim $'<!-- npass:md1 -->\n## Senha\npw\nlixo'
	run "$NPASS" show --render HG a/ruim
	[ "$output" = $'<!-- npass:md1 -->\n## Senha\npw\nlixo' ]
	[ ! -e "$GLOWLOG.in" ]
}

# --- erros e uso -------------------------------------------------------------------------------------------

@test "entrada inexistente e identidade inexistente: erro nos dois modos" {
	run "$NPASS" show HG nao/existe
	[ "$status" -ne 0 ]
	run "$NPASS" show --render HG nao/existe
	[ "$status" -ne 0 ]
	run "$NPASS" show --render NAOEXISTE a/x
	[ "$status" -ne 0 ]
}

@test "sem argumentos mostra uso; opcao desconhecida e recusada" {
	run "$NPASS" show
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso: npass show"* ]]
	run "$NPASS" show --nada HG a/x
	[ "$status" -ne 0 ]
}

@test "o show cru e byte a byte o decifrado: get, clip, otp e extensoes nao mudam" {
	put a/x "$(md1_doc segredo 'login: eu')"
	run "$NPASS" get HG a/x
	[ "$output" = "segredo" ]
	run "$NPASS" show HG a/x
	[ "$output" = "$(md1_doc segredo 'login: eu')" ]
}

@test "help documenta --raw/--render" {
	run "$NPASS" help entradas ver
	[[ "$output" == *"show [--raw|--render] ID DIR/PASS"* ]]
}
