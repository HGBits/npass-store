#!/usr/bin/env bash
# npass - install.sh
#
# Manual (git-clone) install for people not using the AUR package.
# Always rebuilds bin/npass fresh from lib/*.bash first - this script
# never installs a stale artifact that happens to be lying around.
#
# Respects the DESTDIR + PREFIX convention packaging tools expect
# (the AUR PKGBUILD calls this same script with DESTDIR="$pkgdir"
# PREFIX=/usr), so there is exactly one place that knows where files
# go, not two copies of the same install logic drifting apart.
#
#   PREFIX   default: /usr                (system-wide; same as the PKGBUILD)
#   BINDIR   default: $PREFIX/bin         (override to e.g. /usr/sbin)
#   DESTDIR  default: (empty)             (staging root for packaging)
#
# The password store itself is per-user ($HOME/.npass, or $NPASS_STORE);
# only the program is global, so every user on the machine gets `npass`.
# On Arch /usr/sbin is a symlink to /usr/bin, so /usr/bin/npass is
# reachable as /usr/sbin/npass too.
#
# Extensions (extensions/npass-*) are OPTIONAL and nothing about them is
# installed unless you say yes. Run from a terminal, the installer offers
# them after installing npass, one by one, with a short description, and
# puts each accepted one straight into its final place (your extensions
# directory) and signs it with your key. Nothing is asked when stdin is not
# a terminal, when DESTDIR is set (packaging), or with --no-extensions / --no-tui.
#
# Usage:
#   sudo ./install.sh                  install under /usr (bin/npass), then offer extensions
#   sudo ./install.sh --bindir=/usr/sbin   put the binary in /usr/sbin instead
#   ./install.sh --prefix=$HOME/.local     per-user install, no root
#   sudo ./install.sh --uninstall      remove what a prior install put there
#   ./install.sh --prefix=/usr/local [--uninstall]
#   ./install.sh --no-extensions       never offer extensions
#   ./install.sh --tui                  install npass-tui from HGBits/npass_tui
#   ./install.sh --no-tui               do not offer or install npass-tui
#   ./install.sh --extensions          offer extensions even if stdin is not a terminal
#   ./install.sh --extensions-only     skip npass itself, only offer the extensions
#                                      (for the AUR package, or to add one later)
#   ./install.sh --sign-key=KEYID      key used to sign accepted extensions
#                                      (default: gpg's default key)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${PREFIX:=/usr}"
: "${BINDIR:=}"
: "${DESTDIR:=}"
uninstall=0
ext_mode=auto # auto = ask only on a terminal | yes | no
tui_mode=auto # auto = ask only on a terminal | yes | no
ext_only=0
sign_key=""

for arg in "$@"; do
	case "$arg" in
	--uninstall) uninstall=1 ;;
	--prefix=*) PREFIX="${arg#--prefix=}" ;;
	--bindir=*) BINDIR="${arg#--bindir=}" ;;
	--no-extensions) ext_mode=no ;;
	--tui) tui_mode=yes ;;
	--no-tui) tui_mode=no ;;
	--extensions) ext_mode=yes ;;
	--extensions-only) ext_mode=yes; ext_only=1 ;;
	--sign-key=*) sign_key="${arg#--sign-key=}" ;;
	-h | --help)
		awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
		exit 0
		;;
	*)
		echo "install.sh: opção desconhecida: $arg" >&2
		exit 1
		;;
	esac
done

bindir="$DESTDIR${BINDIR:-$PREFIX/bin}"
mandir="$DESTDIR$PREFIX/share/man/man1"
bin_target="$bindir/npass"
tui_target="$bindir/npass-tui"
man_target="$mandir/npass.1"
# The EFF wordlists for `npass diceware` / `npass memorable`. This is the shipped
# TEMPLATE, found by npass relative to its own binary; on first use npass copies it
# into the user's tree ($NPASS_STORE/wordlist.txt), which is where it is read from.
words_dir="$DESTDIR$PREFIX/share/npass/encrypts_alternatives"
words_target="$words_dir/wordlist.txt"
# Handler do esquema npass:// (links do `npass show` renderizado -> `npass open`).
# O Exec leva o caminho ABSOLUTO do binario instalado: a sessao grafica nem sempre
# tem ~/.local/bin no PATH.
desktop_dir="$DESTDIR$PREFIX/share/applications"
desktop_target="$desktop_dir/npass-open.desktop"
npass_final="${BINDIR:-$PREFIX/bin}/npass"

if [[ -n "$DESTDIR" && ( "$ext_mode" == yes || "$tui_mode" == yes ) ]]; then
	echo "install.sh: opções interativas de extensões/TUI não combinam com DESTDIR (empacotamento)." >&2
	exit 1
fi

# --------------------------------------------------------------------------
# Optional extensions
# --------------------------------------------------------------------------

# "# npass-extension-KEY: value" within the first lines of an extension file.
ext_field() {
	sed -n '1,20p' "$1" | sed -n "s/^# npass-extension-$2: *//p" | head -n1
}

# y/N on stdin. Anything but s/sim/y/yes - including EOF - means no.
ask() {
	local a=""
	printf '%s [s/N] ' "$1"
	read -r a || a=""
	[[ -t 0 ]] || echo
	[[ "${a,,}" =~ ^(s|sim|y|yes)$ ]]
}

offer_extensions() {
	local signer="$1"
	local -a candidates=()
	local f
	for f in extensions/npass-*; do
		[[ -f "$f" ]] && candidates+=("$f")
	done
	[[ ${#candidates[@]} -gt 0 ]] || return 0

	echo
	echo "Extensões opcionais:"
	echo "  Rodam como programas seus, com acesso aos seus segredos. Por isso só funcionam"
	echo "  depois de assinadas por VOCÊ e com NPASS_ENABLE_EXTENSIONS=1. Nada é instalado"
	echo "  sem você confirmar."
	ask "Ver e instalar extensões agora?" || return 0

	# The final place is the extensions directory of the user who will RUN npass
	# (under sudo that is SUDO_USER, not root), so ownership and the signing key
	# are theirs.
	local ext_user="${SUDO_USER:-$(id -un)}" ext_home extdir
	ext_home="$(getent passwd "$ext_user" | cut -d: -f6)"
	[[ -n "$ext_home" ]] || ext_home="$HOME"
	if [[ -n "${SUDO_USER:-}" && $EUID -eq 0 ]]; then
		extdir="$ext_home/.local/share/npass/extensions"
	else
		extdir="${NPASS_EXTENSIONS_DIR:-${XDG_DATA_HOME:-$ext_home/.local/share}/npass/extensions}"
	fi

	as_user() {
		if [[ $EUID -eq 0 && "$ext_user" != root ]]; then
			runuser -u "$ext_user" -- env -u GNUPGHOME HOME="$ext_home" "$@"
		else
			"$@"
		fi
	}

	# Shell para checar/compilar com o cargo de QUEM vai rodar o npass: ao trocar de
	# usuário (sudo), um login shell carrega o PATH dele (~/.cargo/bin etc.); sem troca,
	# vale o ambiente atual.
	as_user_sh() {
		if [[ $EUID -eq 0 && "$ext_user" != root ]]; then
			as_user bash -lc "$1"
		else
			bash -c "$1"
		fi
	}

	echo "Destino: $extdir (usuário: $ext_user)"
	local installed=0 name desc needs n dest keyargs tty_dev cargo_spec manifest helper_name built helper_built hdir
	tty_dev="$(tty 2>/dev/null || true)"
	[[ "$tty_dev" == /dev/* ]] || tty_dev=""
	for f in "${candidates[@]}"; do
		name="${f##*/}"
		name="${name%.bash}" # npass-foo.bash is run as `npass foo`, from a file named npass-foo
		desc="$(ext_field "$f" desc)"
		needs="$(ext_field "$f" needs)"
		echo
		echo "  $name - ${desc:-(sem descrição)}"
		if [[ -n "$needs" ]]; then
			for n in $needs; do
				command -v "$n" >/dev/null 2>&1 || echo "    aviso: requer '$n', que não foi encontrado no PATH."
			done
		fi
		cargo_spec="$(ext_field "$f" cargo)"
		ask "  Instalar $name?" || continue

		# Extensão com helper nativo (Rust): só aqui, só porque foi escolhida,
		# o cargo do usuário que vai RODAR o npass compila o código-fonte atual.
		helper_built=""
		if [[ -n "$cargo_spec" ]]; then
			read -r manifest helper_name <<<"$cargo_spec"
			if ! as_user_sh 'command -v cargo' >/dev/null 2>&1; then
				echo "    erro: $name precisa do cargo (Rust) no ambiente de $ext_user, e ele não foi encontrado. Não instalada." >&2
				continue
			fi
			built="$(dirname "$manifest")/target/release/$helper_name"
			# nunca reaproveita binário antigo: apaga o que houver e exige um novo
			rm -f -- "$built" "bin/$helper_name"
			echo "    compilando $helper_name (cargo build --release --locked)..."
			if ! as_user_sh "cd '$PWD' && cargo build --release --locked --manifest-path '$manifest'" >&2 || [[ ! -x "$built" ]]; then
				echo "    erro: a compilação de $helper_name falhou. $name não instalada." >&2
				continue
			fi
			helper_built="$built"
		fi

		dest="$extdir/$name"
		if [[ -z "$helper_built" && -f "$dest" && -f "$dest.sig" ]] && cmp -s "$f" "$dest"; then
			echo "    já instalada, idêntica e assinada: $dest"
			((++installed))
			continue
		fi
		as_user mkdir -p "$extdir"
		as_user chmod 700 "$extdir" 2>/dev/null || true
		as_user rm -f -- "$dest" "$dest.sig"
		as_user install -m 755 -- "$f" "$dest"
		echo "    instalada: $dest"
		((++installed))

		keyargs=()
		[[ -n "$sign_key" ]] && keyargs=("$sign_key")
		if as_user env ${tty_dev:+GPG_TTY="$tty_dev"} "$signer" extension sign "$dest" ${keyargs[@]+"${keyargs[@]}"} >/dev/null; then
			echo "    assinada com a sua chave."
		else
			echo "    aviso: NÃO foi possível assinar. A extensão está no lugar, mas não roda até ser assinada:" >&2
			echo "      npass extension sign $dest" >&2
			continue
		fi

		# Helper nativo: copia, e o PRÓPRIO npass-passkey o sela (selo de compatibilidade
		# + assinatura GPG do helper) - roda pelas portas normais de extensão.
		if [[ -n "$helper_built" ]]; then
			hdir="$(dirname "$extdir")/helpers"
			[[ -n "${NPASS_HELPERS_DIR:-}" ]] && hdir="$NPASS_HELPERS_DIR"
			as_user mkdir -p "$hdir"
			as_user chmod 700 "$hdir" 2>/dev/null || true
			as_user rm -f -- "$hdir/$helper_name" "$hdir/$helper_name.sig" "$hdir/$helper_name.stamp" "$hdir/$helper_name.stamp.sig"
			as_user install -m 755 -- "$helper_built" "$hdir/$helper_name"
			echo "    helper instalado: $hdir/$helper_name"
			if as_user env NPASS_ENABLE_EXTENSIONS=1 NPASS_EXTENSIONS_DIR="$extdir" NPASS_HELPERS_DIR="$hdir" \
				${tty_dev:+GPG_TTY="$tty_dev"} "$signer" "${name#npass-}" seal ${keyargs[@]+"${keyargs[@]}"} >/dev/null; then
				echo "    helper selado e assinado com a sua chave."
			else
				echo "    aviso: NÃO foi possível selar o helper; 'npass passkey serve' recusa até: npass passkey seal" >&2
			fi
		fi
	done

	if [[ $installed -gt 0 ]]; then
		echo
		echo "Para ativar: export NPASS_ENABLE_EXTENSIONS=1   (por exemplo no seu shell rc)"
		echo "Confira com: npass extension list"
	fi
}

# --------------------------------------------------------------------------
# Optional npass-tui
# --------------------------------------------------------------------------

install_tui() {
	local url="https://raw.githubusercontent.com/HGBits/npass_tui/master/npass-tui"
	local tmp
	if ! command -v curl >/dev/null 2>&1; then
		echo "aviso: curl não encontrado; npass-tui não foi instalado." >&2
		return 1
	fi
	tmp="$(mktemp)" || {
		echo "aviso: não foi possível criar arquivo temporário para npass-tui." >&2
		return 1
	}
	if ! curl -fsSL "$url" >"$tmp"; then
		rm -f -- "$tmp"
		echo "aviso: download de npass-tui falhou; a CLI continua instalada." >&2
		return 1
	fi
	if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
		rm -f -- "$tmp"
		echo "aviso: o arquivo baixado para npass-tui está vazio ou tem sintaxe inválida; não instalado." >&2
		return 1
	fi
	if ! install -m 755 -- "$tmp" "$tui_target"; then
		rm -f -- "$tmp"
		echo "aviso: não foi possível instalar npass-tui em $tui_target." >&2
		return 1
	fi
	rm -f -- "$tmp"
	echo "instalado: $tui_target (fonte: $url)"
}

offer_tui() {
	[[ -z "$DESTDIR" && "$tui_mode" != no ]] || return 0
	if [[ "$tui_mode" == yes ]]; then
		install_tui || true
	elif [[ -t 0 && -t 1 ]] && ask "Instalar também a interface de terminal opcional npass-tui?"; then
		install_tui || true
	fi
}

# --------------------------------------------------------------------------
# --extensions-only: do not touch npass itself
# --------------------------------------------------------------------------
if [[ $ext_only -eq 1 ]]; then
	if [[ -x "$bin_target" ]]; then
		signer="$bin_target"
	else
		signer="$(command -v npass 2>/dev/null || true)"
	fi
	if [[ -z "$signer" ]]; then
		echo "install.sh: npass não encontrado. Instale-o antes (sudo ./install.sh)." >&2
		exit 1
	fi
	offer_extensions "$signer"
	exit 0
fi

if [[ $uninstall -eq 1 ]]; then
	removed=0
	for f in "$bin_target" "$tui_target" "$man_target" "$words_target" "$desktop_target"; do
		if [[ -e "$f" ]]; then
			rm -f -- "$f"
			echo "removido: $f"
			removed=1
		fi
	done
	rmdir -- "$words_dir" "$DESTDIR$PREFIX/share/npass" 2>/dev/null || true
	[[ $removed -eq 0 ]] && echo "nada instalado em ${BINDIR:-$PREFIX/bin} (DESTDIR=${DESTDIR:-<vazio>}) para remover."
	exit 0
fi

# Minimum bash: associative arrays (4.0+) and nameref/local -n (4.3+),
# both used throughout lib/*.bash.
bash_major="${BASH_VERSINFO[0]}" bash_minor="${BASH_VERSINFO[1]}"
if (( bash_major < 4 || (bash_major == 4 && bash_minor < 3) )); then
	echo "install.sh: bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} é antigo demais (mínimo 4.3)." >&2
	exit 1
fi

# System-wide default needs root. Fail early with a clear hint instead of
# a bare "Permission denied" halfway through (skipped for DESTDIR staging).
if [[ -z "$DESTDIR" && $EUID -ne 0 ]]; then
	probe="$bindir"
	while [[ ! -d "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
	if [[ ! -w "$probe" ]]; then
		echo "install.sh: sem permissão de escrita em $bindir. Rode com sudo, ou use --prefix=\$HOME/.local para instalar só para você." >&2
		exit 1
	fi
fi

echo "Reconstruindo bin/npass a partir de lib/*.bash..."
bash build.sh

# A instalacao no sistema e legivel por todos de proposito. Com um umask
# restritivo (077 e comum em setups endurecidos, e o sudo mantem o mais
# restritivo entre o seu e o dele) o mkdir abaixo criaria os diretorios novos
# (share/npass, ...) como 0700: os arquivos seriam 644, mas so o root chegaria
# neles, e o npass de um usuario comum nao acharia a lista de palavras. O umask
# volta ao que era antes das etapas por usuario (extensoes).
old_umask="$(umask)"
umask 022

mkdir -p "$bindir" "$mandir" "$words_dir" "$desktop_dir"
install -m 755 bin/npass "$bin_target"
install -m 644 man/npass.1 "$man_target"
install -m 644 encrypts_alternatives/wordlist.txt "$words_target"
sed "s#@NPASS@#$npass_final#" packaging/npass-open.desktop.in >"$desktop_target"
chmod 644 "$desktop_target"
echo "instalado: $bin_target"
echo "instalado: $man_target"
echo "instalado: $words_target"
echo "instalado: $desktop_target"
# Registra o handler npass:// (so fora de empacotamento; o pacote faz isso no hook).
if [[ -z "$DESTDIR" ]] && command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$desktop_dir" 2>/dev/null || true
fi
umask "$old_umask"

# Soft dependency check - informational only. Packaging (the AUR
# PKGBUILD's depends=()) is what actually enforces this; a manual
# git-clone install just gets told what's missing.
missing=()
command -v gpg >/dev/null 2>&1 || missing+=(gpg)
command -v git >/dev/null 2>&1 || missing+=(git)
command -v wl-copy >/dev/null 2>&1 || missing+=(wl-clipboard)
if [[ ${#missing[@]} -gt 0 ]]; then
	echo "aviso: não encontrado no PATH: ${missing[*]} - npass precisa deles em tempo de uso (wl-clipboard só para 'clip'/'otp clip')." >&2
fi
command -v oathtool >/dev/null 2>&1 || command -v otptool >/dev/null 2>&1 \
	|| echo "aviso: nem oathtool nem otptool encontrados - 'npass otp' não vai funcionar até um dos dois ser instalado." >&2
command -v qrencode >/dev/null 2>&1 \
	|| echo "aviso: qrencode não encontrado - 'npass otp uri -q' (QR no terminal) não vai funcionar." >&2
command -v glow >/dev/null 2>&1 \
	|| echo "aviso: glow não encontrado - 'npass show' em terminal vai imprimir o texto cru em vez do markdown renderizado." >&2

case ":$PATH:" in
*":$bindir:"*) ;;
*) echo "aviso: $bindir não está no seu \$PATH. Adicione, por exemplo, 'export PATH=\"$bindir:\$PATH\"' ao seu shell rc." >&2 ;;
esac

# Optional extensions: only offered when a human can answer (terminal), never
# while packaging (DESTDIR), and only if asked for or not disabled.
if [[ -z "$DESTDIR" && "$tui_mode" != no ]]; then
	offer_tui
fi

if [[ -z "$DESTDIR" && "$ext_mode" != no ]]; then
	if [[ "$ext_mode" == yes || ( -t 0 && -t 1 ) ]]; then
		offer_extensions "$bin_target"
	fi
fi
