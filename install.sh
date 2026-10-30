#!/usr/bin/env bash
# npass - install.sh
#
# Manual install for people not using the AUR package.
# By default, installs the signed core bundle from the official GitHub Release.
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
# Extensions are optional. When requested, only artifacts already signed by the
# packaged NPASS release key are installed to the system-wide XDG data directory.
# The installer never signs code and never uses the invoking user's private key.
#
# Where the extensions come from, in this order:
#   1. --extensions-src=DIR (or $NPASS_EXTENSIONS_SRC): a checkout of
#      npass-extensions or an extracted signed release bundle. A bundle root
#      contains extensions/ and helpers/; passkey is skipped without its signed helper.
#   2. ../npass-extensions, next to this repository, if it has a signed bundle for this target.
#   3. Otherwise it asks before downloading a signed release bundle from GitHub.
#      The bundle and each individual artifact are verified against the packaged
#      release key before anything is installed.
#
# The complete core bundle (binary, man page, wordlist, desktop template and trust key)
# is signed as one release artifact. The installer verifies it before extraction.
#
# npass-tui is NOT built here. It is a signed binary published as a release of
# HGBits/npass-tui (files npass-tui and npass-tui.asc). The installer downloads
# both over https, verifies the detached signature in a throwaway GnuPG home that
# holds ONLY the release public key (the installed release key), requires the
# signing key to be exactly that key, and only then installs the binary. Any
# failure (download, key, signature, syntax) installs nothing; with --tui it also
# makes install.sh exit non-zero at the end.
#
# Usage:
#   sudo ./install.sh                  download, verify and install official core under /usr
#   sudo ./install.sh --core-ref=TAG   install core from a specific release
#   ./install.sh --core-key=FILE       use a separately verified release public key
#   sudo ./install.sh --bindir=/usr/sbin   put the binary in /usr/sbin instead
#   ./install.sh --prefix=$HOME/.local     per-user install, no root
#   sudo ./install.sh --uninstall      remove what a prior install put there
#   ./install.sh --prefix=/usr/local [--uninstall]
#   ./install.sh --no-extensions       never offer extensions
#   ./install.sh --tui                  download, VERIFY and install npass-tui (signed release)
#   ./install.sh --tui-ref=TAG          release tag to download (default: the latest release)
#   ./install.sh --tui-key=FILE         public key to verify npass-tui with (replaces the
#                                       trust root $release_key; $NPASS_TUI_KEY)
#   ./install.sh --no-tui               do not offer or install npass-tui
#   ./install.sh --extensions          offer extensions even if stdin is not a terminal
#   ./install.sh --extensions-only     skip npass itself, only offer the extensions
#                                      (for the AUR package, or to add one later)
#   ./install.sh --extensions-src=DIR  take extensions from a checkout or extracted signed bundle
#   ./install.sh --extensions-ref=TAG  release tag to download (default: latest)
#   ./install.sh --extensions-target=TRIPLE  Rust target (auto-detected on common Linux hosts)

set -euo pipefail

# A checkout is optional. When piped to bash, all core files arrive in the
# signed release archive; the caller's working directory is not treated as source.
script_path="${BASH_SOURCE[0]:-}"
remote_stdin=0
if [[ -n "$script_path" && -f "$script_path" ]]; then
	source_root="$(cd "$(dirname "$script_path")" && pwd)"
	cd "$source_root"
else
	remote_stdin=1
	source_root="$PWD"
fi
release_key="$source_root/packaging/npass-release.asc"


: "${PREFIX:=/usr}"
: "${BINDIR:=}"
: "${DESTDIR:=}"
uninstall=0
ext_mode=auto # auto = ask only on a terminal | yes | no
tui_mode=auto # auto = ask only on a terminal | yes | no
ext_only=0
ext_src="${NPASS_EXTENSIONS_SRC:-}"
ext_helper_src=""
ext_selected_src=""
ext_ref=""
ext_target="${NPASS_EXTENSIONS_TARGET:-}"
ext_release_base="${NPASS_EXTENSIONS_RELEASES:-https://github.com/HGBits/npass-extensions/releases}"
ext_tmp=""
tui_ref=""
tui_key="${NPASS_TUI_KEY:-}"
tui_base="${NPASS_TUI_BASE_URL:-https://github.com/HGBits/npass-tui/releases}"
tui_failed=0
core_ref="${NPASS_CORE_REF:-}"
core_base="${NPASS_CORE_BASE_URL:-https://github.com/HGBits/npass-store/releases}"
core_key="${NPASS_CORE_KEY:-}"

for arg in "$@"; do
	case "$arg" in
	--uninstall) uninstall=1 ;;
	--prefix=*) PREFIX="${arg#--prefix=}" ;;
	--bindir=*) BINDIR="${arg#--bindir=}" ;;
	--no-extensions) ext_mode=no ;;
	--core-ref=*) core_ref="${arg#--core-ref=}" ;;
	--core-key=*) core_key="${arg#--core-key=}" ;;
	--tui) tui_mode=yes ;;
	--no-tui) tui_mode=no ;;
	--tui-ref=*) tui_ref="${arg#--tui-ref=}" ;;
	--tui-key=*) tui_key="${arg#--tui-key=}" ;;
	--extensions) ext_mode=yes ;;
	--extensions-only) ext_mode=yes; ext_only=1 ;;
	--extensions-src=*) ext_src="${arg#--extensions-src=}" ;;
	--extensions-ref=*) ext_ref="${arg#--extensions-ref=}" ;;
	--extensions-target=*) ext_target="${arg#--extensions-target=}" ;;
	-h | --help)
		if (( remote_stdin )); then
			printf '%s\n' "Uso: install.sh [--core-ref=TAG] [--prefix=PATH] [--no-extensions] [--no-tui]"
			printf '%s\n' "Instala o pacote core completo de uma GitHub Release assinada, sem clone."
		else
			awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
		fi
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
trust_key_target="$DESTDIR$PREFIX/share/npass/extension-signing-key.asc"
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

# A directory counts as an extensions checkout if it holds at least one npass-* file.
ext_valid_src() {
	local f
	for f in "$1"/npass-*; do
		[[ -f "$f" ]] && return 0
	done
	return 1
}

detect_extensions_target() {
	if [[ -z "$ext_target" ]]; then
		local arch libc=gnu
		case "$(uname -m)" in
			x86_64) arch=x86_64 ;;
			aarch64|arm64) arch=aarch64 ;;
			*) return 1 ;;
		esac
		if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then libc=musl; fi
		ext_target="$arch-unknown-linux-$libc"
	fi
	[[ "$ext_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# Local source only (no network). Prints the ABSOLUTE path. Returns 1 for an
# explicit source that is unusable (hard error), 2 when there is no local copy.
find_ext_src() {
	local cand selected
	ext_helper_src=""
	ext_selected_src=""

	if [[ -n "$ext_src" ]]; then
		if [[ -d "$ext_src/extensions" ]] && ext_valid_src "$ext_src/extensions"; then
			ext_helper_src="$ext_src/helpers"
			ext_selected_src="$(cd "$ext_src/extensions" && pwd)"
			return 0
		fi
		if [[ -d "$ext_src" ]] && ext_valid_src "$ext_src"; then
			if detect_extensions_target &&
				[[ -d "$ext_src/dist/$ext_target/extensions" &&
				   -d "$ext_src/dist/$ext_target/helpers" ]] &&
				ext_valid_src "$ext_src/dist/$ext_target/extensions"; then
				selected="$ext_src/dist/$ext_target"
				ext_helper_src="$selected/helpers"
				ext_selected_src="$(cd "$selected/extensions" && pwd)"
			else
				ext_selected_src="$(cd "$ext_src" && pwd)"
			fi
			return 0
		fi
		echo "install.sh: sem extensões ou pacote de release válido em: $ext_src" >&2
		return 1
	fi

	local base
	base="$(cd .. && pwd)"
	for cand in "$base/npass-extensions"; do
		if [[ -d "$cand" ]] &&
			ext_valid_src "$cand" &&
			detect_extensions_target &&
			[[ -d "$cand/dist/$ext_target/extensions" &&
			   -d "$cand/dist/$ext_target/helpers" ]] &&
			ext_valid_src "$cand/dist/$ext_target/extensions"; then
			selected="$cand/dist/$ext_target"
			ext_helper_src="$selected/helpers"
			ext_selected_src="$(cd "$selected/extensions" && pwd)"
			return 0
		fi
	done
	return 2
}
extension_safe_parent_tree() {
	local PATH=/usr/bin:/bin:/usr/sbin:/sbin
	local path="$1" meta uid mode
	[[ "$path" != *"/../"* && "$path" != */.. && "$path" != *"/./"* && "$path" != */. && "$path" != *"//"* ]] || return 1
	while [[ "$path" != "/" ]]; do
		[[ -d "$path" && ! -L "$path" ]] || return 1
		meta="$(stat -c '%u:%a' -- "$path" 2>/dev/null)" || return 1
		uid="${meta%%:*}"; mode="${meta#*:}"
		[[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
		(( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
		path="${path%/*}"; [[ -n "$path" ]] || path="/"
	done
	return 0
}

offer_extensions() {
	local PATH=/usr/bin:/bin:/usr/sbin:/sbin
	local -a candidates=()
	local f src rc=0
	find_ext_src || rc=$?
	src="$ext_selected_src"
	((rc == 1)) && return 1

	echo
	echo "Extensões oficiais:"
	echo "  Somente artefatos com assinatura válida da chave de release do NPASS serão instalados."
	echo "  A instalação é compartilhada pelo sistema e requer privilégios administrativos."
	ask "Verificar e instalar extensões oficiais agora?" || return 0

	if ((rc == 2)); then
		echo "  Não achei um checkout local nem um pacote de release extraído."
		ask "  Baixar o pacote oficial assinado de extensões?" || return 0
		command -v curl >/dev/null 2>&1 || { echo "install.sh: curl não encontrado." >&2; return 1; }
		command -v tar >/dev/null 2>&1 || { echo "install.sh: tar não encontrado." >&2; return 1; }
		detect_extensions_target || { echo "install.sh: informe --extensions-target=TRIPLE para esta arquitetura/target." >&2; return 1; }
		ext_tmp="$(mktemp -d "${TMPDIR:-/tmp}/npass-ext-release.XXXXXX")" || return 1
		trap 'GNUPGHOME="$ext_tmp/gnupg" gpgconf --kill all 2>/dev/null || true; rm -rf -- "$ext_tmp"' EXIT
		local bundle="$ext_tmp/npass-extensions-$ext_target.tar.gz" bundle_sig="$ext_tmp/npass-extensions-$ext_target.tar.gz.sig"
		local release_url="$ext_release_base/latest/download"
		[[ -n "$ext_ref" ]] && release_url="$ext_release_base/download/$ext_ref"
		if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 180 --max-filesize 67108864 -o "$bundle" -- "$release_url/npass-extensions-$ext_target.tar.gz" ||
			! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 120 --max-filesize 1048576 -o "$bundle_sig" -- "$release_url/npass-extensions-$ext_target.tar.gz.sig"; then
			echo "install.sh: não foi possível baixar o pacote oficial para $ext_target." >&2
			return 1
		fi
		local bundle_gh="$ext_tmp/gnupg" bundle_fpr bundle_status bundle_line
		local -a bundle_fields=()
		local bundle_gpg
		bundle_gpg="$(command -v gpg)" || { echo "install.sh: gpg não encontrado." >&2; return 1; }
		mkdir -m 700 "$bundle_gh"
		if ! GNUPGHOME="$bundle_gh" "$bundle_gpg" --batch --quiet --import "$release_key" 2>/dev/null; then
			echo "install.sh: não foi possível importar a chave pública oficial." >&2
			return 1
		fi
		[[ "$(GNUPGHOME="$bundle_gh" "$bundle_gpg" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)" == 1 ]] || {
			echo "install.sh: chave pública oficial inválida." >&2; return 1;
		}
		bundle_fpr="$(GNUPGHOME="$bundle_gh" "$bundle_gpg" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
		bundle_status="$(GNUPGHOME="$bundle_gh" "$bundle_gpg" --batch --no-auto-key-retrieve --status-fd=1 --verify "$bundle_sig" "$bundle" 2>/dev/null)" || {
			echo "install.sh: assinatura do pacote de extensões inválida." >&2; return 1;
		}
		bundle_line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$bundle_status" | head -n1)"
		read -r -a bundle_fields <<<"$bundle_line"
		[[ "${bundle_fields[11]:-${bundle_fields[2]:-}}" == "$bundle_fpr" ]] || {
			echo "install.sh: pacote não assinado pela chave oficial." >&2; return 1;
		}
		if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$bundle_status"; then
			echo "install.sh: assinatura do pacote não é válida e vigente." >&2; return 1
		fi
		if ! tar -tzf "$bundle" >"$ext_tmp/archive-entries"; then
			echo "install.sh: pacote de extensões não é um tar.gz válido." >&2
			return 1
		fi
		while IFS= read -r entry; do
			case "$entry" in
				extensions/|helpers/|extensions/*|helpers/*) ;;
				*) echo "install.sh: caminho inesperado no pacote: $entry" >&2; return 1 ;;
			esac
			[[ "$entry" != /* && "$entry" != *"/../"* && "$entry" != ../* && "$entry" != */.. && "$entry" != *"//"* ]] || {
				echo "install.sh: caminho inseguro no pacote: $entry" >&2; return 1;
			}
		done <"$ext_tmp/archive-entries"
		if ! tar -tvzf "$bundle" >"$ext_tmp/archive-details"; then
			echo "install.sh: não foi possível inspecionar os tipos de arquivo do pacote." >&2
			return 1
		fi
		while IFS= read -r entry; do
			case "${entry:0:1}" in
				-|d) ;;
				*) echo "install.sh: links e arquivos especiais não são permitidos no pacote." >&2; return 1 ;;
			esac
		done <"$ext_tmp/archive-details"
		mkdir -p "$ext_tmp/bundle"
		tar --no-same-owner --no-same-permissions -xzf "$bundle" -C "$ext_tmp/bundle"
		src="$ext_tmp/bundle/extensions"
		ext_helper_src="$ext_tmp/bundle/helpers"
		ext_valid_src "$src" || { echo "install.sh: pacote oficial não contém extensões." >&2; return 1; }
		GNUPGHOME="$bundle_gh" gpgconf --kill all 2>/dev/null || true
		echo "  Release oficial: ${ext_ref:-latest} ($ext_target)"
	fi

	if [[ -z "$DESTDIR" && $EUID -ne 0 ]]; then
		echo "install.sh: a instalação compartilhada de extensões requer root." >&2
		return 1
	fi
	local extdir="$DESTDIR$PREFIX/share/npass/extensions"
	local trust_key="$release_key"
	local installed_key="$DESTDIR$PREFIX/share/npass/extension-signing-key.asc"
	if [[ ! -s "$trust_key" ]]; then
		echo "install.sh: chave pública oficial ausente: $trust_key" >&2
		return 1
	fi
	for f in "$src"/npass-*; do
		[[ -f "$f" && "$f" != *.sig ]] && candidates+=("$f")
	done
	(("${#candidates[@]}" > 0)) || {
		echo "install.sh: nenhuma extensão encontrada em $src."
		return 0
	}

	local work gh nprim fpr status_out line primary name desc sig stage installed=0 gpg_bin gpgconf_bin helper_stage helper_ready=0 passkey_installed=0 helperdir helper_tmp artifact proto hsha esha
	local -a status_fields=()
	gpg_bin="$(PATH=/usr/bin:/bin command -v gpg)" || { echo "install.sh: gpg não encontrado." >&2; return 1; }
	gpgconf_bin="$(PATH=/usr/bin:/bin command -v gpgconf)" || true
	work="$(mktemp -d "${TMPDIR:-/tmp}/npass-ext-install.XXXXXX")" || return 1
	gh="$work/gnupg"
	mkdir -m 700 "$gh"
	if ! GNUPGHOME="$gh" "$gpg_bin" --batch --quiet --import "$trust_key" 2>/dev/null; then
		echo "install.sh: não foi possível importar a chave pública oficial." >&2
		rm -rf -- "$work"; return 1
	fi
	nprim="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
	if [[ "$nprim" != 1 ]]; then
		echo "install.sh: a chave oficial deve conter exatamente uma chave primária." >&2
		if [[ -n "$gpgconf_bin" ]]; then GNUPGHOME="$gh" "$gpgconf_bin" --kill all 2>/dev/null || true; fi
		rm -rf -- "$work"; return 1
	fi
	fpr="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
	[[ -n "$fpr" ]] || { rm -rf -- "$work"; return 1; }

	# The passkey daemon is a separately built, separately signed release artifact.
	# Copy first, then verify staged bytes; never build or sign it as the installing user.
	helper_stage="$work/passkey-helper"
	if [[ -n "$ext_helper_src" && -d "$ext_helper_src" ]]; then
		mkdir -m 700 "$helper_stage"
		helper_ready=1
		for artifact in npass-passkeyd npass-passkeyd.stamp; do
			if [[ -L "$ext_helper_src/$artifact" || ! -f "$ext_helper_src/$artifact" ||
				-L "$ext_helper_src/$artifact.sig" || ! -f "$ext_helper_src/$artifact.sig" ]]; then
				helper_ready=0
				break
			fi
			if [[ "$artifact" == npass-passkeyd ]]; then
				install -m 755 -- "$ext_helper_src/$artifact" "$helper_stage/$artifact" || helper_ready=0
			else
				install -m 644 -- "$ext_helper_src/$artifact" "$helper_stage/$artifact" || helper_ready=0
			fi
			install -m 644 -- "$ext_helper_src/$artifact.sig" "$helper_stage/$artifact.sig" || helper_ready=0
			((helper_ready)) || break
			status_out="$(GNUPGHOME="$gh" "$gpg_bin" --batch --no-auto-key-retrieve --status-fd=1 --verify "$helper_stage/$artifact.sig" "$helper_stage/$artifact" 2>/dev/null)" || {
				helper_ready=0; break;
			}
			line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status_out" | head -n1)"
			read -r -a status_fields <<<"$line"
			primary="${status_fields[11]:-${status_fields[2]:-}}"
			if [[ "$primary" != "$fpr" ]] || grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$status_out"; then
				helper_ready=0; break
			fi
		done
		if ((helper_ready)); then
			proto="$(sed -n 's/^proto  *//p' "$helper_stage/npass-passkeyd.stamp" | head -n1)"
			hsha="$(sed -n 's/^helper-sha256  *//p' "$helper_stage/npass-passkeyd.stamp" | head -n1)"
			esha="$(sed -n 's/^extension-sha256  *//p' "$helper_stage/npass-passkeyd.stamp" | head -n1)"
			[[ "$(head -n1 "$helper_stage/npass-passkeyd.stamp")" == npass-passkeyd-stamp-v1 &&
				"$proto" == 1 &&
				"$hsha" == "$(sha256sum "$helper_stage/npass-passkeyd" | awk '{print $1}')" &&
				"$esha" == "$(sha256sum "$src/npass-passkey" | awk '{print $1}')" &&
				-x "$helper_stage/npass-passkeyd" ]] || helper_ready=0
		fi
		if ((!helper_ready)); then
			echo "  aviso: pacote do daemon passkey ausente ou inválido; npass-passkey será ignorada."
			rm -rf -- "$helper_stage"
		fi
	else
		echo "  aviso: pacote do daemon passkey não encontrado; npass-passkey será ignorada."
	fi

	local share_dir="$DESTDIR$PREFIX/share" npass_dir="$DESTDIR$PREFIX/share/npass"
	if ! extension_safe_parent_tree "$share_dir"; then
		echo "install.sh: PREFIX/share precisa existir em uma árvore root-owned e não gravável por outros usuários." >&2
		rm -rf -- "$work"
		return 1
	fi
	if [[ -e "$npass_dir" || -L "$npass_dir" ]] && ! extension_safe_parent_tree "$npass_dir"; then
		echo "install.sh: diretório compartilhado do NPASS tem proprietário, link ou permissões inseguras." >&2
		rm -rf -- "$work"
		return 1
	fi
	if [[ -e "$extdir" || -L "$extdir" ]] && ! extension_safe_parent_tree "$extdir"; then
		echo "install.sh: diretório de extensões tem proprietário, link ou permissões inseguras." >&2
		rm -rf -- "$work"
		return 1
	fi
	mkdir -p "$npass_dir" "$extdir"
	if [[ -L "$installed_key" || ( -e "$installed_key" && ! -f "$installed_key" ) ]]; then
		echo "install.sh: destino da chave de confiança não é um arquivo regular; recusado." >&2
		rm -rf -- "$work"
		return 1
	fi
	local key_tmp
	key_tmp="$(mktemp "$npass_dir/.extension-key.XXXXXX")" || { rm -rf -- "$work"; return 1; }
	install -m 644 "$trust_key" "$key_tmp"
	chown root:root "$key_tmp"
	mv -f -- "$key_tmp" "$installed_key"
	chmod 755 "$npass_dir" "$extdir"
	chown root:root "$npass_dir" "$extdir" "$installed_key"
	echo "Origem: $src"
	echo "Destino: $extdir"
	for f in "${candidates[@]}"; do
		name="${f##*/}"; name="${name%.bash}"
		sig="$f.sig"
		if [[ ! "$name" =~ ^npass-[a-z0-9][a-z0-9-]*$ ]]; then
			echo "    recusada: nome de extensão inválido."
			continue
		fi
		desc="$(ext_field "$f" desc)"
		echo "  $name - ${desc:-(sem descrição)}"
		if [[ "$name" == npass-passkey && "$helper_ready" -ne 1 ]]; then
			echo "    ignorada: falta o daemon oficial assinado para este target."
			continue
		fi
		if [[ -L "$f" || ! -f "$f" || -L "$sig" || ! -f "$sig" ]]; then
			echo "    recusada: executável ou assinatura ausente/não regular."
			continue
		fi
		# Copy first, then verify the staged bytes. The source checkout is user-controlled
		# and must not be able to swap the executable after signature verification.
		stage="$(mktemp -d "$extdir/.stage.XXXXXX")" || continue
		if ! install -m 755 -- "$f" "$stage/npass-$name" ||
			! install -m 644 -- "$sig" "$stage/npass-$name.sig"; then
			rm -rf -- "$stage"; continue
		fi
		status_out="$(GNUPGHOME="$gh" "$gpg_bin" --batch --no-auto-key-retrieve --status-fd=1 --verify "$stage/npass-$name.sig" "$stage/npass-$name" 2>/dev/null)" || {
			echo "    recusada: assinatura inválida."
			rm -rf -- "$stage"
			continue
		}
		line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status_out" | head -n1)"
		read -r -a status_fields <<<"$line"
		primary="${status_fields[11]:-${status_fields[2]:-}}"
		if [[ "$primary" != "$fpr" ]] || grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$status_out"; then
			echo "    recusada: assinatura não pertence à chave oficial."
			rm -rf -- "$stage"
			continue
		fi
		chown -R root:root "$stage" 2>/dev/null || true
		if [[ -L "$extdir/npass-$name" || -L "$extdir/npass-$name.sig" || ( -e "$extdir/npass-$name" && ! -f "$extdir/npass-$name" ) || ( -e "$extdir/npass-$name.sig" && ! -f "$extdir/npass-$name.sig" ) ]]; then
			echo "    recusada: destino existente não é arquivo regular."
			rm -rf -- "$stage"
			continue
		fi
		mv -f -- "$stage/npass-$name" "$extdir/npass-$name"
		mv -f -- "$stage/npass-$name.sig" "$extdir/npass-$name.sig"
		rmdir -- "$stage"
		echo "    instalada e verificada."
		((++installed))
		[[ "$name" == npass-passkey ]] && passkey_installed=1
	done

	if ((passkey_installed)); then
		helperdir="$DESTDIR$PREFIX/share/npass/helpers"
		if [[ -L "$helperdir" || ( -e "$helperdir" && ! -d "$helperdir" ) ]]; then
			echo "install.sh: destino do helper não é um diretório regular; recusado." >&2
			rm -f -- "$extdir/npass-passkey" "$extdir/npass-passkey.sig"
			rm -rf -- "$work"; return 1
		fi
		mkdir -p "$helperdir"
		if ! extension_safe_parent_tree "$helperdir"; then
			echo "install.sh: árvore do helper compartilhado tem proprietário ou permissões inseguras." >&2
			rm -f -- "$extdir/npass-passkey" "$extdir/npass-passkey.sig"
			rm -rf -- "$work"; return 1
		fi
		chmod 755 "$helperdir"; chown root:root "$helperdir"
		for artifact in npass-passkeyd npass-passkeyd.sig npass-passkeyd.stamp npass-passkeyd.stamp.sig; do
			if [[ -L "$helperdir/$artifact" || ( -e "$helperdir/$artifact" && ! -f "$helperdir/$artifact" ) ]]; then
				echo "install.sh: destino existente do helper não é arquivo regular: $artifact" >&2
				rm -f -- "$extdir/npass-passkey" "$extdir/npass-passkey.sig"
				rm -rf -- "$work"; return 1
			fi
		done
		helper_tmp="$(mktemp -d "$helperdir/.stage.XXXXXX")" || {
			rm -f -- "$extdir/npass-passkey" "$extdir/npass-passkey.sig"
			rm -rf -- "$work"; return 1;
		}
		install -m 755 -- "$helper_stage/npass-passkeyd" "$helper_tmp/npass-passkeyd"
		install -m 644 -- "$helper_stage/npass-passkeyd.sig" "$helper_tmp/npass-passkeyd.sig"
		install -m 644 -- "$helper_stage/npass-passkeyd.stamp" "$helper_tmp/npass-passkeyd.stamp"
		install -m 644 -- "$helper_stage/npass-passkeyd.stamp.sig" "$helper_tmp/npass-passkeyd.stamp.sig"
		chown -R root:root "$helper_tmp"
		mv -f -- "$helper_tmp/npass-passkeyd" "$helperdir/npass-passkeyd"
		mv -f -- "$helper_tmp/npass-passkeyd.sig" "$helperdir/npass-passkeyd.sig"
		mv -f -- "$helper_tmp/npass-passkeyd.stamp" "$helperdir/npass-passkeyd.stamp"
		mv -f -- "$helper_tmp/npass-passkeyd.stamp.sig" "$helperdir/npass-passkeyd.stamp.sig"
		rmdir -- "$helper_tmp"
		echo "  daemon passkey instalado e verificado em $helperdir"
	fi
	if [[ -n "$gpgconf_bin" ]]; then GNUPGHOME="$gh" "$gpgconf_bin" --kill all 2>/dev/null || true; fi
	rm -rf -- "$work"
	echo "Extensões oficiais instaladas: $installed"
	echo "Confira com: npass extension list"
}

# --------------------------------------------------------------------------
# Optional npass-tui
# --------------------------------------------------------------------------

# Download + verify + install, all inside "$1" (a private temp dir). Returns 0
# only after the signature was verified AND the binary was installed.
tui_fetch_verify() {
	local work="$1" key url bin asc gh fpr nprim status_out line last f gpg_bin
	gpg_bin="$(command -v gpg)" || return 1
	key="${tui_key:-$release_key}"
	if [[ ! -s "$key" ]]; then
		echo "aviso: chave pública de release não encontrada: $key" >&2
		echo "       sem ela não há como verificar o npass-tui; nada foi baixado nem instalado." >&2
		return 1
	fi
	local tool
	for tool in curl gpg; do
		command -v "$tool" >/dev/null 2>&1 || {
			echo "aviso: $tool não encontrado; npass-tui não foi instalado." >&2
			return 1
		}
	done

	# Keyring descartável: só a chave de release, nunca o chaveiro do usuário.
	gh="$work/gnupg"
	mkdir -m 700 "$gh"
	if ! GNUPGHOME="$gh" "$gpg_bin" --batch --quiet --import "$key" 2>/dev/null; then
		echo "aviso: não foi possível importar $key." >&2
		return 1
	fi
	nprim="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
	if [[ "$nprim" != 1 ]]; then
		echo "aviso: $key deve conter exatamente UMA chave pública (tem $nprim); recusado." >&2
		return 1
	fi
	fpr="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
	[[ -n "$fpr" ]] || {
		echo "aviso: não consegui ler o fingerprint da chave de release." >&2
		return 1
	}

	if [[ -n "$tui_ref" ]]; then
		url="$tui_base/download/$tui_ref"
	else
		url="$tui_base/latest/download"
	fi
	bin="$work/npass-tui"
	asc="$work/npass-tui.asc"
	for f in "npass-tui:$bin" "npass-tui.asc:$asc"; do
		if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--max-time 120 --max-filesize 16777216 -o "${f#*:}" -- "$url/${f%%:*}"; then
			echo "aviso: falha ao baixar $url/${f%%:*}; npass-tui não instalado." >&2
			return 1
		fi
	done
	[[ -s "$bin" && -s "$asc" ]] || {
		echo "aviso: download vazio; npass-tui não instalado." >&2
		return 1
	}

	# Aceita só: gpg com status 0, GOODSIG e VALIDSIG cuja chave primária é a de
	# release. Nada de BADSIG/ERRSIG/EXPKEYSIG/EXPSIG/REVKEYSIG.
	if ! status_out="$(GNUPGHOME="$gh" "$gpg_bin" --batch --status-fd 1 --verify "$asc" "$bin" 2>/dev/null)"; then
		echo "aviso: assinatura de npass-tui INVÁLIDA (ou de outra chave); nada instalado." >&2
		return 1
	fi
	if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG)' <<<"$status_out" \
		|| ! grep -q '^\[GNUPG:\] GOODSIG' <<<"$status_out"; then
		echo "aviso: assinatura de npass-tui não é uma assinatura boa e vigente; nada instalado." >&2
		return 1
	fi
	line="$(grep '^\[GNUPG:\] VALIDSIG' <<<"$status_out" | head -n1)"
	last="${line##* }"
	if [[ -z "$line" || "$last" != "$fpr" ]]; then
		echo "aviso: npass-tui não foi assinado pela chave de release ($fpr); nada instalado." >&2
		return 1
	fi

	if ! bash -n "$bin" 2>/dev/null; then
		echo "aviso: npass-tui assinado, mas com sintaxe inválida; nada instalado." >&2
		return 1
	fi
	if ! install -m 755 -- "$bin" "$tui_target"; then
		echo "aviso: não foi possível instalar npass-tui em $tui_target." >&2
		return 1
	fi
	echo "instalado: $tui_target (assinatura verificada; chave $fpr; origem: $url)"
}

install_tui() {
	local work rc=0
	work="$(mktemp -d "${TMPDIR:-/tmp}/npass-tui.XXXXXX")" || {
		echo "aviso: não foi possível criar diretório temporário para npass-tui." >&2
		return 1
	}
	tui_fetch_verify "$work" || rc=$?
	GNUPGHOME="$work/gnupg" gpgconf --kill gpg-agent 2>/dev/null || true
	rm -rf -- "$work"
	return "$rc"
}

offer_tui() {
	[[ -z "$DESTDIR" && "$tui_mode" != no ]] || return 0
	if [[ "$tui_mode" == yes ]]; then
		install_tui || { tui_failed=1; echo "aviso: a CLI continua instalada; npass-tui não." >&2; }
	elif [[ -t 0 && -t 1 ]] && ask "Instalar também a interface de terminal opcional npass-tui (binário assinado, verificado)?"; then
		install_tui || echo "aviso: a CLI continua instalada; npass-tui não." >&2
	fi
}

# --------------------------------------------------------------------------
# Core release: download and verify the signed npass artifact before install
# --------------------------------------------------------------------------

core_fetch_verify() {
	local work="$1" gh="$1/gnupg" gpg_bin fpr nprim url bundle bundle_sig key_file status_out line key_hash
	local -a fields=()
	command -v curl >/dev/null 2>&1 || { echo "install.sh: curl não encontrado." >&2; return 1; }
	gpg_bin="$(command -v gpg)" || { echo "install.sh: gpg não encontrado." >&2; return 1; }
	if [[ -n "$core_ref" ]]; then
		[[ "$core_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "install.sh: tag de release inválida: $core_ref" >&2; return 1; }
		url="$core_base/download/$core_ref"
	else
		url="$core_base/latest/download"
	fi

	key_file="$core_key"
	if [[ -z "$key_file" ]]; then
		if (( ! remote_stdin )) && [[ -s "$release_key" && ! -L "$release_key" ]]; then
			key_file="$release_key"
		else
			key_file="$work/npass-release.asc"
			if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 1048576 -o "$key_file" -- "$url/npass-release.asc"; then
				echo "install.sh: falha ao baixar a chave pública de release." >&2; return 1
			fi
			key_hash="$(sha256sum "$key_file" | awk '{print $1}')"
			[[ "$key_hash" == "b6d37eaf8dd854eb8083e6f4eec300d9f13a99fedb7882a4bb44fd85fd028fe1" ]] || {
				echo "install.sh: a chave pública baixada não corresponde à chave oficial fixada no instalador." >&2; return 1;
			}
		fi
	fi
	[[ -s "$key_file" && ! -L "$key_file" ]] || { echo "install.sh: chave pública de release ausente ou inválida: $key_file" >&2; return 1; }
	mkdir -m 700 "$gh"
	if ! GNUPGHOME="$gh" "$gpg_bin" --batch --quiet --import "$key_file" 2>/dev/null; then
		echo "install.sh: não foi possível importar a chave pública de release." >&2; return 1
	fi
	nprim="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
	[[ "$nprim" == 1 ]] || { echo "install.sh: a chave pública de release deve conter exatamente uma chave primária." >&2; return 1; }
	fpr="$(GNUPGHOME="$gh" "$gpg_bin" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
	[[ "$fpr" =~ ^[A-Fa-f0-9]{40,64}$ ]] || { echo "install.sh: fingerprint da chave de release inválida." >&2; return 1; }

	bundle="$work/npass-core.tar.gz"; bundle_sig="$bundle.asc"
	if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 180 --max-filesize 67108864 -o "$bundle" -- "$url/npass-core.tar.gz" ||
		! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 120 --max-filesize 1048576 -o "$bundle_sig" -- "$url/npass-core.tar.gz.asc"; then
		echo "install.sh: falha ao baixar o pacote core assinado de $url." >&2; return 1
	fi
	[[ -s "$bundle" && -s "$bundle_sig" && ! -L "$bundle" && ! -L "$bundle_sig" ]] || { echo "install.sh: pacote core vazio ou inválido; nada instalado." >&2; return 1; }
	if ! status_out="$(GNUPGHOME="$gh" "$gpg_bin" --batch --no-auto-key-retrieve --status-fd=1 --verify "$bundle_sig" "$bundle" 2>/dev/null)"; then
		echo "install.sh: assinatura do pacote core INVÁLIDA; nada instalado." >&2; return 1
	fi
	if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$status_out" ||
		! grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status_out"; then
		echo "install.sh: assinatura do pacote core não é válida e vigente; nada instalado." >&2; return 1
	fi
	line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status_out" | head -n1)"
	read -r -a fields <<<"$line"
	[[ -n "$line" && "${fields[11]:-${fields[2]:-}}" == "$fpr" ]] || { echo "install.sh: pacote core não foi assinado pela chave de release esperada ($fpr)." >&2; return 1; }

	# Archive allow-list + type check before extraction: no traversal, symlinks or special files.
	if ! tar -tzf "$bundle" >"$work/archive-entries" || ! tar -tvzf "$bundle" >"$work/archive-details"; then
		echo "install.sh: pacote core não é um tar.gz válido." >&2; return 1
	fi
	while IFS= read -r entry; do
		case "$entry" in
			bin/|bin/npass|share/|share/applications/|share/applications/npass-open.desktop.in|share/man/|share/man/man1/|share/man/man1/npass.1|share/npass/|share/npass/encrypts_alternatives/|share/npass/encrypts_alternatives/wordlist.txt|share/npass/extension-signing-key.asc) ;;
			*) echo "install.sh: caminho inesperado no pacote core: $entry" >&2; return 1 ;;
		esac
		[[ "$entry" != /* && "$entry" != *"/../"* && "$entry" != ../* && "$entry" != */.. && "$entry" != *"//"* ]] || { echo "install.sh: caminho inseguro no pacote core: $entry" >&2; return 1; }
	done <"$work/archive-entries"
	while IFS= read -r entry; do
		case "${entry:0:1}" in -|d) ;; *) echo "install.sh: links e arquivos especiais não são permitidos no pacote core." >&2; return 1 ;; esac
	done <"$work/archive-details"
	mkdir -m 700 "$work/payload"
	tar --no-same-owner --no-same-permissions -xzf "$bundle" -C "$work/payload"
	for f in bin/npass share/man/man1/npass.1 share/npass/encrypts_alternatives/wordlist.txt share/applications/npass-open.desktop.in share/npass/extension-signing-key.asc; do
		[[ -f "$work/payload/$f" && ! -L "$work/payload/$f" && -s "$work/payload/$f" ]] || { echo "install.sh: pacote core incompleto: $f ausente ou inválido." >&2; return 1; }
	done
	cmp -s -- "$key_file" "$work/payload/share/npass/extension-signing-key.asc" || { echo "install.sh: chave incluída no pacote não corresponde à chave usada para verificá-lo." >&2; return 1; }
	[[ -x "$work/payload/bin/npass" ]] || chmod 755 "$work/payload/bin/npass"
	bash -n "$work/payload/bin/npass" 2>/dev/null || { echo "install.sh: binário do pacote core tem sintaxe inválida; nada instalado." >&2; return 1; }
	printf '%s\n' "$work/payload/bin/npass"
	echo "release core verificada: $url (pacote completo; chave $fpr)" >&2
}

# --------------------------------------------------------------------------
# --extensions-only: do not touch npass itself
# --------------------------------------------------------------------------
if [[ $ext_only -eq 1 ]]; then
	if (( remote_stdin )) && [[ -z "$core_key" ]]; then
		core_work="$(mktemp -d "${TMPDIR:-/tmp}/npass-core-key.XXXXXX")"
		if [[ -n "$core_ref" ]]; then key_url="$core_base/download/$core_ref"; else key_url="$core_base/latest/download"; fi
		curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 1048576 -o "$core_work/npass-release.asc" -- "$key_url/npass-release.asc" || exit 1
		[[ "$(sha256sum "$core_work/npass-release.asc" | awk '{print $1}')" == "b6d37eaf8dd854eb8083e6f4eec300d9f13a99fedb7882a4bb44fd85fd028fe1" ]] || { echo "install.sh: chave pública remota não corresponde à chave oficial." >&2; exit 1; }
		release_key="$core_work/npass-release.asc"
	elif [[ -n "$core_key" ]]; then
		release_key="$core_key"
	fi
	if [[ ! -x "$bin_target" ]] && ! command -v npass >/dev/null 2>&1; then
		echo "install.sh: npass não encontrado. Instale-o antes." >&2
		exit 1
	fi
	offer_extensions
	[[ -z "$core_work" ]] || rm -rf -- "$core_work"
	exit 0
fi

if [[ $uninstall -eq 1 ]]; then
	removed=0
	for f in "$bin_target" "$tui_target" "$man_target" "$words_target" "$desktop_target" "$trust_key_target"; do
		if [[ -e "$f" ]]; then
			rm -f -- "$f"
			echo "removido: $f"
			removed=1
		fi
	done
	rm -rf -- "$DESTDIR$PREFIX/share/npass/extensions" "$DESTDIR$PREFIX/share/npass/helpers"
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

core_work=""
core_bin=""
core_payload_dir=""
core_man=""
core_words=""
core_desktop=""
core_install_key=""
core_work="$(mktemp -d "${TMPDIR:-/tmp}/npass-core-release.XXXXXX")" || {
	echo "install.sh: não foi possível criar diretório temporário para o release." >&2
	exit 1
}
trap 'if [[ -n "${core_work:-}" && -d "$core_work" ]]; then GNUPGHOME="$core_work/gnupg" gpgconf --kill all 2>/dev/null || true; rm -rf -- "$core_work"; fi' EXIT
if ! core_bin="$(core_fetch_verify "$core_work")"; then
	GNUPGHOME="$core_work/gnupg" gpgconf --kill all 2>/dev/null || true
	rm -rf -- "$core_work"
	core_work=""
	exit 1
fi
core_payload_dir="$core_work/payload"
core_man="$core_payload_dir/share/man/man1/npass.1"
core_words="$core_payload_dir/share/npass/encrypts_alternatives/wordlist.txt"
core_desktop="$core_payload_dir/share/applications/npass-open.desktop.in"
core_install_key="$core_payload_dir/share/npass/extension-signing-key.asc"

# A instalacao no sistema e legivel por todos de proposito. Com um umask
# restritivo (077 e comum em setups endurecidos, e o sudo mantem o mais
# restritivo entre o seu e o dele) o mkdir abaixo criaria os diretorios novos
# (share/npass, ...) como 0700: os arquivos seriam 644, mas so o root chegaria
# neles, e o npass de um usuario comum nao acharia a lista de palavras. O umask
# volta ao que era antes das etapas por usuario (extensoes).
old_umask="$(umask)"
umask 022

mkdir -p "$bindir" "$mandir" "$words_dir" "$desktop_dir" "$DESTDIR$PREFIX/share/npass"
if [[ -L "$DESTDIR$PREFIX/share" || -L "$DESTDIR$PREFIX/share/npass" || -L "$trust_key_target" || ( -e "$trust_key_target" && ! -f "$trust_key_target" ) ]]; then
	echo "install.sh: destino da chave de confiança contém link ou não é arquivo regular." >&2
	exit 1
fi
key_tmp="$(mktemp "$DESTDIR$PREFIX/share/npass/.extension-key.XXXXXX")"
install -m 644 -- "$core_install_key" "$key_tmp"
mv -f -- "$key_tmp" "$trust_key_target"
install -m 755 -- "$core_bin" "$bin_target"
install -m 644 "$core_man" "$man_target"
install -m 644 "$core_words" "$words_target"
sed "s#@NPASS@#$npass_final#" "$core_desktop" >"$desktop_target"
chmod 644 "$desktop_target"
echo "instalado: $bin_target"
echo "instalado: $man_target"
echo "instalado: $words_target"
echo "instalada chave de confiança das extensões: $trust_key_target"
echo "instalado: $desktop_target"
# Registra o handler npass:// (so fora de empacotamento; o pacote faz isso no hook).
if [[ -z "$DESTDIR" ]] && command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$desktop_dir" 2>/dev/null || true
fi
umask "$old_umask"
release_key="$trust_key_target"
if [[ -n "$core_work" ]]; then
	GNUPGHOME="$core_work/gnupg" gpgconf --kill all 2>/dev/null || true
	rm -rf -- "$core_work"
	core_work=""
	trap - EXIT
fi

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
		offer_extensions
	fi
fi

exit "$tui_failed"
