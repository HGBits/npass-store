#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
	cat <<'EOF'
Uso: ./release.sh [DIRETORIO_DE_SAIDA]

Gera o pacote completo de release e o assina com a chave privada de release
já presente no chaveiro GPG do mantenedor.

Saída padrão: dist/
Assets para anexar à GitHub Release:
  npass-core.tar.gz
  npass-core.tar.gz.asc
  npass-release.asc

A chave privada nunca é exportada nem gravada no repositório.
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	"") ;;
	*) [[ $# -eq 1 ]] || { usage >&2; exit 2; } ;;
esac

out_dir="${1:-dist}"
key="packaging/npass-release.asc"
command -v gpg >/dev/null 2>&1 || { echo "release.sh: gpg não encontrado." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "release.sh: tar não encontrado." >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "release.sh: gzip não encontrado." >&2; exit 1; }
[[ -s "$key" && ! -L "$key" ]] || { echo "release.sh: chave pública ausente ou inválida: $key" >&2; exit 1; }

# The package always uses a fresh build; no stale bin/npass can leak into a release.
bash build.sh
[[ -x bin/npass ]] || { echo "release.sh: build.sh não gerou bin/npass executável." >&2; exit 1; }
bash -n bin/npass
for f in man/npass.1 encrypts_alternatives/wordlist.txt packaging/npass-open.desktop.in; do
	[[ -s "$f" && ! -L "$f" ]] || { echo "release.sh: arquivo obrigatório ausente ou inválido: $f" >&2; exit 1; }
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/npass-release.XXXXXX")"
trap 'GNUPGHOME="$tmp/gnupg" gpgconf --kill all >/dev/null 2>&1 || true; rm -rf -- "$tmp"' EXIT
stage="$tmp/stage"
mkdir -m 700 "$stage" "$tmp/gnupg"
install -D -m 755 -- bin/npass "$stage/bin/npass"
install -D -m 644 -- man/npass.1 "$stage/share/man/man1/npass.1"
install -D -m 644 -- encrypts_alternatives/wordlist.txt "$stage/share/npass/encrypts_alternatives/wordlist.txt"
install -D -m 644 -- packaging/npass-open.desktop.in "$stage/share/applications/npass-open.desktop.in"
install -D -m 644 -- "$key" "$stage/share/npass/extension-signing-key.asc"

if ! GNUPGHOME="$tmp/gnupg" gpg --batch --quiet --import "$key"; then
	echo "release.sh: não foi possível importar a chave pública de release." >&2
	exit 1
fi
primary_count="$(GNUPGHOME="$tmp/gnupg" gpg --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
[[ "$primary_count" == 1 ]] || { echo "release.sh: a chave deve conter exatamente uma chave primária." >&2; exit 1; }
fingerprint="$(GNUPGHOME="$tmp/gnupg" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[[ "$fingerprint" =~ ^[A-Fa-f0-9]{40,64}$ ]] || { echo "release.sh: fingerprint inválida." >&2; exit 1; }
secret_count="$(gpg --batch --with-colons --list-secret-keys "$fingerprint" 2>/dev/null | grep -c '^sec:' || true)"
[[ "$secret_count" -ge 1 ]] || {
	echo "release.sh: a chave privada correspondente à fingerprint $fingerprint não está disponível." >&2
	exit 1
}

mkdir -p "$out_dir"
bundle_tmp="$tmp/npass-core.tar.gz"
tar --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" --owner=0 --group=0 --numeric-owner -cf - -C "$stage" bin share | gzip -n >"$bundle_tmp"
[[ -s "$bundle_tmp" ]] || { echo "release.sh: pacote vazio." >&2; exit 1; }
if ! gpg --batch --yes --no-tty --armor --detach-sign --local-user "$fingerprint" --output "$tmp/npass-core.tar.gz.asc" "$bundle_tmp"; then
	echo "release.sh: falha ao assinar. Verifique seu chaveiro GPG." >&2
	exit 1
fi
status="$(GNUPGHOME="$tmp/gnupg" gpg --batch --no-auto-key-retrieve --status-fd=1 --verify "$tmp/npass-core.tar.gz.asc" "$bundle_tmp" 2>/dev/null)" || {
	echo "release.sh: a assinatura gerada não passou na verificação." >&2
	exit 1
}
valid_line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status" | head -n1)"
read -r -a valid_fields <<<"$valid_line"
signing_fingerprint="${valid_fields[11]:-${valid_fields[2]:-}}"
[[ "$signing_fingerprint" == "$fingerprint" ]] || { echo "release.sh: assinatura feita por chave inesperada." >&2; exit 1; }

install -m 644 -- "$bundle_tmp" "$out_dir/npass-core.tar.gz"
install -m 644 -- "$tmp/npass-core.tar.gz.asc" "$out_dir/npass-core.tar.gz.asc"
install -m 644 -- "$key" "$out_dir/npass-release.asc"
echo "release pronta em: $out_dir"
echo "fingerprint: $fingerprint"
echo "assets: npass-core.tar.gz, npass-core.tar.gz.asc, npass-release.asc"
