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
# a terminal, when DESTDIR is set (packaging), or with --no-extensions.
#
# Usage:
#   sudo ./install.sh                  install under /usr (bin/npass), then offer extensions
#   sudo ./install.sh --bindir=/usr/sbin   put the binary in /usr/sbin instead
#   ./install.sh --prefix=$HOME/.local     per-user install, no root
#   sudo ./install.sh --uninstall      remove what a prior install put there
#   ./install.sh --prefix=/usr/local [--uninstall]
#   ./install.sh --no-extensions       never offer extensions
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
ext_only=0
sign_key=""

for arg in "$@"; do
	case "$arg" in
	--uninstall) uninstall=1 ;;
	--prefix=*) PREFIX="${arg#--prefix=}" ;;
	--bindir=*) BINDIR="${arg#--bindir=}" ;;
	--no-extensions) ext_mode=no ;;
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
man_target="$mandir/npass.1"
# The EFF wordlists for `npass diceware` / `npass memorable`. This is the shipped
# TEMPLATE, found by npass relative to its own binary; on first use npass copies it
# into the user's tree ($NPASS_STORE/wordlist.txt), which is where it is read from.
words_dir="$DESTDIR$PREFIX/share/npass/encrypts_alternatives"
words_target="$words_dir/wordlist.txt"

if [[ -n "$DESTDIR" && "$ext_mode" == yes ]]; then
	echo "install.sh: extensões moram no diretório do usuário e são assinadas por ele; não combinam com DESTDIR (empacotamento)." >&2
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

	echo "Destino: $extdir (usuário: $ext_user)"
	local installed=0 name desc needs n dest keyargs tty_dev
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
		ask "  Instalar $name?" || continue

		dest="$extdir/$name"
		if [[ -f "$dest" && -f "$dest.sig" ]] && cmp -s "$f" "$dest"; then
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
		fi
	done

	if [[ $installed -gt 0 ]]; then
		echo
		echo "Para ativar: export NPASS_ENABLE_EXTENSIONS=1   (por exemplo no seu shell rc)"
		echo "Confira com: npass extension list"
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
	for f in "$bin_target" "$man_target" "$words_target"; do
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

mkdir -p "$bindir" "$mandir" "$words_dir"
install -m 755 bin/npass "$bin_target"
install -m 644 man/npass.1 "$man_target"
install -m 644 encrypts_alternatives/wordlist.txt "$words_target"
echo "instalado: $bin_target"
echo "instalado: $man_target"
echo "instalado: $words_target"

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

case ":$PATH:" in
*":$bindir:"*) ;;
*) echo "aviso: $bindir não está no seu \$PATH. Adicione, por exemplo, 'export PATH=\"$bindir:\$PATH\"' ao seu shell rc." >&2 ;;
esac

# Optional extensions: only offered when a human can answer (terminal), never
# while packaging (DESTDIR), and only if asked for or not disabled.
if [[ -z "$DESTDIR" && "$ext_mode" != no ]]; then
	if [[ "$ext_mode" == yes || ( -t 0 && -t 1 ) ]]; then
		offer_extensions "$bin_target"
	fi
fi
