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
# Usage:
#   sudo ./install.sh                  install under /usr (bin/npass)
#   sudo ./install.sh --bindir=/usr/sbin   put the binary in /usr/sbin instead
#   ./install.sh --prefix=$HOME/.local     per-user install, no root
#   sudo ./install.sh --uninstall      remove what a prior install put there
#   ./install.sh --prefix=/usr/local [--uninstall]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${PREFIX:=/usr}"
: "${BINDIR:=}"
: "${DESTDIR:=}"
uninstall=0

for arg in "$@"; do
	case "$arg" in
	--uninstall) uninstall=1 ;;
	--prefix=*) PREFIX="${arg#--prefix=}" ;;
	--bindir=*) BINDIR="${arg#--bindir=}" ;;
	-h | --help)
		sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
# Bundled extensions are shipped under share/npass/extensions and are NOT
# enabled or trusted by the install: the user copies one into their own
# extensions dir and signs it with `npass extension install FILE`.
extdir="$DESTDIR$PREFIX/share/npass/extensions"
ext_target="$extdir/npass-import"

if [[ $uninstall -eq 1 ]]; then
	removed=0
	for f in "$bin_target" "$man_target" "$ext_target"; do
		if [[ -e "$f" ]]; then
			rm -f -- "$f"
			echo "removido: $f"
			removed=1
		fi
	done
	rmdir -- "$extdir" "$DESTDIR$PREFIX/share/npass" 2>/dev/null || true
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

mkdir -p "$bindir" "$mandir" "$extdir"
install -m 755 bin/npass "$bin_target"
install -m 644 man/npass.1 "$man_target"
install -m 755 extensions/npass-import "$ext_target"
echo "instalado: $bin_target"
echo "instalado: $man_target"
echo "instalado: $ext_target"
echo "  (para usar a extensão de importação: npass extension install $PREFIX/share/npass/extensions/npass-import"
echo "   e depois export NPASS_ENABLE_EXTENSIONS=1)"

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
command -v python3 >/dev/null 2>&1 \
	|| echo "aviso: python3 não encontrado - a extensão npass-import (npass import) não vai funcionar." >&2
command -v qrencode >/dev/null 2>&1 \
	|| echo "aviso: qrencode não encontrado - 'npass otp uri -q' (QR no terminal) não vai funcionar." >&2

case ":$PATH:" in
*":$bindir:"*) ;;
*) echo "aviso: $bindir não está no seu \$PATH. Adicione, por exemplo, 'export PATH=\"$bindir:\$PATH\"' ao seu shell rc." >&2 ;;
esac
