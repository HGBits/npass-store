#!/usr/bin/env bats
# npass open npass://ID/caminho (lib/17-open.bash): o alvo dos links do show renderizado.
# O que importa: so MOSTRA, confirma ANTES de decifrar, parser estrito, e abre um
# terminal so por NPASS_TERMINAL (nenhum teste aciona a autodeteccao: rodar a suite
# nao pode abrir janela de verdade na maquina de quem testa).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v python3 >/dev/null || skip "python3 nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	unset NPASS_OPEN_CONFIRM NPASS_OPEN_TIMEOUT TERMINAL
	export NPASS_TERMINAL="$BATS_TEST_TMPDIR/nunca-existe-terminal"   # rede de seguranca
	export MOCKBIN="$BATS_TEST_TMPDIR/mockbin" CLIPFILE="$BATS_TEST_TMPDIR/clip.out"
	mkdir -p "$MOCKBIN"
	printf '#!/bin/bash\ncat > "%s"\n' "$CLIPFILE" >"$MOCKBIN/wl-copy"
	chmod +x "$MOCKBIN"/*
	export PATH="$MOCKBIN:$PATH" WAYLAND_DISPLAY=wayland-test
	"$NPASS" init HG "$FPR" >/dev/null
}

put() { printf '%s\0%s\0' "$1" "$2" | "$NPASS" insert --batch -f HG >/dev/null; }

# fn CHAMADA...: roda uma funcao interna do npass (codificacao de URL, deteccao de terminal)
fn() {
	NPASS_SRC="$NPASS" "$BASH" -c 'source <(sed "\$d" "$NPASS_SRC"); "$@"' _ "$@"
}

# --- codificacao de URL ----------------------------------------------------------------------------

@test "encode: so A-Za-z0-9 . _ ~ - / ficam; espaco, #, ?, %, \\, aspas e UTF-8 viram %XX" {
	run fn npass_url_encode 'a b/ção#1?x%y\z"w'"'"
	[ "$status" -eq 0 ]
	[ "$output" = 'a%20b/%C3%A7%C3%A3o%231%3Fx%25y%5Cz%22w%27' ]
	[[ "$output" =~ ^[A-Za-z0-9._~/%-]+$ ]]
}

@test "decode(encode(x)) == x para nomes dificeis" {
	local n
	for n in 'a b/c' 'ção/日本語' 'x#y?z%w' 'a\b' '100%/ok' "aspas'duplas\"" 'a+b' '~til/_u.-'; do
		local e; e="$(fn npass_url_encode "$n")"
		run fn npass_url_decode "$e"
		[ "$status" -eq 0 ]
		[ "$output" = "$n" ]
	done
}

@test "decode recusa %-escape incompleto, nao hexadecimal e NUL" {
	local bad
	for bad in 'a%' 'a%4' 'a%zz' 'a%4z' 'a%00b' 'a%0'; do
		run fn npass_url_decode "$bad"
		[ "$status" -ne 0 ]
	done
}

# --- parser ------------------------------------------------------------------------------------------

@test "URLs invalidas sao recusadas com a mensagem de URL, sem decifrar nada" {
	local u
	for u in 'http://HG/a' 'npass:/HG/a' 'npass://HG' 'npass://HG/' 'npass://H G/a' 'npass://HG/a/' \
		'npass://HG/../etc' 'npass://HG/a/../b' 'npass://HG/%2e%2e/b' 'npass://HG/a/%2E%2E/b' 'npass://HG/a%00b' 'npass://HG/a%zz' \
		'npass://HG/a%0Ab' 'npass://HG/a%09b' 'npass:///a' 'npass://HG//a' 'HG/a' ''; do
		NPASS_OPEN_CONFIRM=0 NPASS_GPG=/bin/false run "$NPASS" open --here "$u"
		[ "$status" -ne 0 ]
		[[ "$output" == *"URL inválida"* || "$output" == *"uso: npass open"* ]]
	done
}

@test "query e fragmento sao ignorados; ID com ponto, traco e underscore e aceito" {
	"$NPASS" init a.b-c_1 "$FPR" >/dev/null
	printf 'x\nx\n' | "$NPASS" insert a.b-c_1 a/b >/dev/null
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here 'npass://a.b-c_1/a/b?x=1#frag'
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Senha"* ]]
}

# --- mostrar, e so mostrar ----------------------------------------------------------------------------

@test "open --here mostra a entrada (nome com espaco, acento, # e ?) como o show" {
	local name='a b/ção#1?x%y'
	put "$name" "$(md1_doc segredo 'login: eu')"
	local url; url="npass://HG/$(fn npass_url_encode "$name")"
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here "$url"
	[ "$status" -eq 0 ]
	[ "$output" = "$(md1_doc segredo 'login: eu')" ]
}

@test "open so mostra: nao copia, nao grava, nao muda o repositorio" {
	put a/x "$(md1_doc segredo)"
	local antes; antes="$(git -C "$NPASS_STORE" rev-parse HEAD)"
	NPASS_OPEN_CONFIRM=0 "$NPASS" open --here 'npass://HG/a/x' >/dev/null
	[ ! -e "$CLIPFILE" ]
	[ "$(git -C "$NPASS_STORE" rev-parse HEAD)" = "$antes" ]
	[ -z "$(git -C "$NPASS_STORE" status --porcelain)" ]
}

@test "entrada ou identidade inexistente: erro, status != 0" {
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here 'npass://HG/nao/existe'
	[ "$status" -ne 0 ]
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here 'npass://NAOEXISTE/a'
	[ "$status" -ne 0 ]
}

@test "renderiza em terminal real (pty) pelo glow, como o show" {
	put a/x "$(md1_doc segredo)"
	printf '#!/bin/bash\ncat >/dev/null\nprintf "<<GLOW>>\\n"\n' >"$BATS_TEST_TMPDIR/glow"
	chmod +x "$BATS_TEST_TMPDIR/glow"
	NPASS_GLOW="$BATS_TEST_TMPDIR/glow" NPASS_OPEN_CONFIRM=0 run python3 - "$NPASS" <<'PY'
import os, pty, subprocess, sys
m, s = pty.openpty()
p = subprocess.Popen([sys.argv[1], "open", "npass://HG/a/x"], stdout=s, stdin=subprocess.DEVNULL, close_fds=True)
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
sys.stdout.write(out.decode(errors="replace"))
PY
	[[ "$output" == *"<<GLOW>>"* ]]
}

# --- confirmacao ---------------------------------------------------------------------------------------------

@test "confirmacao: y mostra; n, vazio e EOF cancelam (status 1)" {
	put a/x "$(md1_doc segredo)"
	run bash -c "printf 'y\n' | '$NPASS' open --here npass://HG/a/x"
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Senha"* ]]
	for ans in 'n\n' '\n' ''; do
		run bash -c "printf '$ans' | '$NPASS' open --here npass://HG/a/x"
		[ "$status" -eq 1 ]
		[[ "$output" == *"Cancelado"* ]]
		[[ "$output" != *"segredo"* ]]
	done
}

@test "a confirmacao vem ANTES de qualquer decifragem (gpg quebrado nao importa se disser n)" {
	put a/x "$(md1_doc segredo)"
	NPASS_GPG=/bin/false run bash -c "printf 'n\n' | '$NPASS' open --here npass://HG/a/x"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Cancelado"* ]]
}

@test "NPASS_OPEN_CONFIRM=0 pula a confirmacao" {
	put a/x "$(md1_doc segredo)"
	NPASS_OPEN_CONFIRM=0 run "$NPASS" open --here npass://HG/a/x </dev/null
	[ "$status" -eq 0 ]
}

# --- sem terminal: abre uma janela ---------------------------------------------------------------------------

@test "sem tty (chamado pelo desktop): lanca NPASS_TERMINAL rodando 'open --here --pause URL'" {
	printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\n' "$BATS_TEST_TMPDIR/term.args" >"$BATS_TEST_TMPDIR/faketerm"
	chmod +x "$BATS_TEST_TMPDIR/faketerm"
	NPASS_TERMINAL="$BATS_TEST_TMPDIR/faketerm --flag" run "$NPASS" open 'npass://HG/a/x'
	[ "$status" -eq 0 ]
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BATS_TEST_TMPDIR/term.args" ] && break; sleep 0.2; done
	run cat "$BATS_TEST_TMPDIR/term.args"
	[ "${lines[0]}" = "--flag" ]
	[[ "${lines[1]}" == */npass ]]
	[ "${lines[2]}" = "open" ]
	[ "${lines[3]}" = "--here" ]
	[ "${lines[4]}" = "--pause" ]
	[ "${lines[5]}" = "npass://HG/a/x" ]
}

@test "o launcher nao decifra nem mostra nada: so abre a janela (a confirmacao e la)" {
	printf '#!/bin/bash\ntrue\n' >"$BATS_TEST_TMPDIR/faketerm"
	chmod +x "$BATS_TEST_TMPDIR/faketerm"
	NPASS_GPG=/bin/false NPASS_TERMINAL="$BATS_TEST_TMPDIR/faketerm" run "$NPASS" open 'npass://HG/a/x'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "URL invalida nunca lanca terminal" {
	printf '#!/bin/bash\ntouch "%s"\n' "$BATS_TEST_TMPDIR/lancou" >"$BATS_TEST_TMPDIR/faketerm"
	chmod +x "$BATS_TEST_TMPDIR/faketerm"
	NPASS_TERMINAL="$BATS_TEST_TMPDIR/faketerm" run "$NPASS" open 'npass://HG/a/../x'
	[ "$status" -ne 0 ]
	sleep 0.5
	[ ! -e "$BATS_TEST_TMPDIR/lancou" ]
}

# --- escolha do terminal (so a funcao: nada e executado) -------------------------------------------------------

# detect [ENV=VAL...]: roda npass_open_terminal com PATH so do dir fakepath e imprime o prefixo
# escolhido (ou rc=N). O codigo das funcoes e extraido ANTES, com o PATH normal.
detect() {
	sed '$d' "$NPASS" >"$BATS_TEST_TMPDIR/npass.src"
	env -i PATH="$BATS_TEST_TMPDIR/fakepath" "$@" "$BASH" -c 'source "$1"; if npass_open_terminal; then printf "%s|" "${NPASS_OPEN_TERM[@]}"; else printf "rc=1"; fi' _ "$BATS_TEST_TMPDIR/npass.src"
}

@test "deteccao de terminal: NPASS_TERMINAL manda, depois TERMINAL (-e), depois foot/kitty/alacritty/wezterm/xterm" {
	local d="$BATS_TEST_TMPDIR/fakepath"; mkdir -p "$d"
	run detect "NPASS_TERMINAL=meu term --x"
	[ "$output" = "meu|term|--x|" ]
	touch "$d/xterm" "$d/kitty"; chmod +x "$d/xterm" "$d/kitty"
	run detect
	[ "$output" = "kitty|" ]
	rm "$d/kitty"
	run detect
	[ "$output" = "xterm|-e|" ]
	touch "$d/foot" "$d/alacritty"; chmod +x "$d/foot" "$d/alacritty"
	run detect
	[ "$output" = "foot|" ]
	rm "$d/foot"
	run detect
	[ "$output" = "alacritty|-e|" ]
	touch "$d/meuterm"; chmod +x "$d/meuterm"
	run detect TERMINAL=meuterm
	[ "$output" = "meuterm|-e|" ]
	run detect TERMINAL=naoexiste
	[ "$output" = "alacritty|-e|" ]
}

@test "nenhum terminal disponivel: a funcao falha (e o open mostra o erro claro, sem chutar um)" {
	mkdir -p "$BATS_TEST_TMPDIR/fakepath"
	run detect
	[ "$output" = "rc=1" ]
	# e pelo comando: sem NPASS_TERMINAL e com PATH sem terminais
	sed '$d' "$NPASS" >"$BATS_TEST_TMPDIR/npass.src"
	run env -i PATH="$BATS_TEST_TMPDIR/fakepath" "$BASH" -c 'source "$1"; cmd_open npass://HG/a/x' _ "$BATS_TEST_TMPDIR/npass.src"
	[ "$status" -ne 0 ]
	[[ "$output" == *"não achei um terminal"* ]]
}

# --- --pause -------------------------------------------------------------------------------------------------------

@test "--pause em terminal real: espera, e limpa tela e scrollback no fim" {
	put a/x "$(md1_doc segredo)"
	NPASS_OPEN_CONFIRM=0 run python3 - "$NPASS" <<'PY'
import os, pty, subprocess, sys
m, s = pty.openpty()
p = subprocess.Popen([sys.argv[1], "open", "--here", "--pause", "npass://HG/a/x"], stdout=s, stdin=subprocess.DEVNULL, close_fds=True)
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
sys.stdout.write(out.decode(errors="replace").replace("\x1b", "<ESC>"))
PY
	[[ "$output" == *"<ESC>[2J<ESC>[3J<ESC>[H"* ]]
}

@test "--pause fora de terminal nao emite escape de limpeza" {
	put a/x "$(md1_doc segredo)"
	NPASS_OPEN_CONFIRM=0 run bash -c "printf '\n' | '$NPASS' open --here --pause npass://HG/a/x"
	[ "$status" -eq 0 ]
	[[ "$output" != *$'\033'* ]]
}

# --- uso e help ------------------------------------------------------------------------------------------------------

@test "uso: sem URL, --help e opcao desconhecida; help lista o open" {
	run "$NPASS" open
	[ "$status" -ne 0 ]
	[[ "$output" == *"uso: npass open"* ]]
	run "$NPASS" open --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--here"* ]]
	run "$NPASS" open --nada npass://HG/a
	[ "$status" -ne 0 ]
	run "$NPASS" help backup navegar
	[[ "$output" == *"open [--here] [--pause] npass://ID/DIR/PASS"* ]]
}
