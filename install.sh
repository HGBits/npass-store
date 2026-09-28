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
#   PREFIX   default: $HOME/.local        (per-user, no root needed)
#   DESTDIR  default: (empty)             (staging root for packaging)
#
# Usage:
#   ./install.sh                 install under $HOME/.local
#   PREFIX=/usr/local ./install.sh   install system-wide (needs write access)
#   ./install.sh --uninstall     remove what a prior install put there
#   ./install.sh --prefix=/usr/local [--uninstall]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${PREFIX:="$HOME/.local"}"
: "${DESTDIR:=}"
uninstall=0

for arg in "$@"; do
	case "$arg" in
	--uninstall) uninstall=1 ;;
	--prefix=*) PREFIX="${arg#--prefix=}" ;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "install.sh: opção desconhecida: $arg" >&2
		exit 1
		;;
	esac
done

bindir="$DESTDIR$PREFIX/bin"
mandir="$DESTDIR$PREFIX/share/man/man1"
bin_target="$bindir/npass"
man_target="$mandir/npass.1"

if [[ $uninstall -eq 1 ]]; then
	removed=0
	for f in "$bin_target" "$man_target"; do
		if [[ -e "$f" ]]; then
			rm -f -- "$f"
			echo "removido: $f"
			removed=1
		fi
	done
	[[ $removed -eq 0 ]] && echo "nada instalado em $PREFIX (DESTDIR=${DESTDIR:-<vazio>}) para remover."
	exit 0
fi

# Minimum bash: associative arrays (4.0+) and nameref/local -n (4.3+),
# both used throughout lib/*.bash.
bash_major="${BASH_VERSINFO[0]}" bash_minor="${BASH_VERSINFO[1]}"
if (( bash_major < 4 || (bash_major == 4 && bash_minor < 3) )); then
	echo "install.sh: bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} é antigo demais (mínimo 4.3)." >&2
	exit 1
fi

echo "Reconstruindo bin/npass a partir de lib/*.bash..."
bash build.sh

mkdir -p "$bindir" "$mandir"
install -m 755 bin/npass "$bin_target"
install -m 644 man/npass.1 "$man_target"
echo "instalado: $bin_target"
echo "instalado: $man_target"

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
