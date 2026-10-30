#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
	cat <<'EOF'
Uso: ./build.sh [--sign]

Gera bin/npass a partir de lib/*.bash.
  --sign   assina bin/npass com a chave privada correspondente à chave
           pública de release em packaging/npass-release.asc.
           Gera a assinatura destacada ASCII em bin/npass.asc.

A chave privada nunca é lida de arquivos do repositório nem copiada para ele.
A assinatura exige que a chave privada de release já esteja disponível no
chaveiro GPG do mantenedor.
EOF
}

sign=0
for arg in "$@"; do
	case "$arg" in
		--sign) sign=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "build.sh: opção desconhecida: $arg" >&2; usage >&2; exit 2 ;;
	esac
done

out="bin/npass"
sig="$out.asc"
key="packaging/npass-release.asc"
mkdir -p "$(dirname "$out")"

{
	echo '#!/usr/bin/env bash'
	echo '# GENERATED FILE - built by build.sh from lib/*.bash. Do not edit directly.'
	for f in lib/*.bash; do
		[[ "$f" == "lib/00-main.bash" ]] && continue
		tail -n +2 "$f"
		echo
	done
	tail -n +2 lib/00-main.bash
} >"$out"
chmod +x "$out"
rm -f -- "$sig"
echo "built: $out"

if (( ! sign )); then
	echo "unsigned build (use ./build.sh --sign to create a release signature)"
	exit 0
fi

command -v gpg >/dev/null 2>&1 || {
	echo "build.sh: gpg não encontrado; instale GnuPG para assinar releases." >&2
	exit 1
}
[[ -s "$key" ]] || {
	echo "build.sh: chave pública de release ausente: $key" >&2
	exit 1
}

# Import the public key into an isolated keyring to derive the trust-root
# fingerprint. The maintainer's normal keyring is used only for signing.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/npass-build-sign.XXXXXX")"
trap 'GNUPGHOME="$tmp/gnupg" gpgconf --kill all >/dev/null 2>&1 || true; rm -rf -- "$tmp"' EXIT
mkdir -m 700 "$tmp/gnupg"
if ! GNUPGHOME="$tmp/gnupg" gpg --batch --quiet --import "$key"; then
	echo "build.sh: não foi possível importar a chave pública de release." >&2
	exit 1
fi

primary_count="$(GNUPGHOME="$tmp/gnupg" gpg --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
[[ "$primary_count" == 1 ]] || {
	echo "build.sh: a chave pública deve conter exatamente uma chave primária." >&2
	exit 1
}
fingerprint="$(GNUPGHOME="$tmp/gnupg" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ "$fingerprint" =~ ^[A-Fa-f0-9]{40,64}$ ]] || {
	echo "build.sh: não foi possível determinar a fingerprint da chave de release." >&2
	exit 1
}

echo "signing: $out"
if ! gpg --batch --yes --no-tty --armor --detach-sign \
	--local-user "$fingerprint" --output "$sig" "$out"; then
	rm -f -- "$sig"
	echo "build.sh: falha ao assinar. Verifique se a chave privada correspondente está no seu chaveiro GPG." >&2
	exit 1
fi
chmod 644 "$sig"

# Verify the exact output against the packaged public trust root before
# reporting success. This also rejects signatures made by another key.
if ! status="$(GNUPGHOME="$tmp/gnupg" gpg --batch --no-auto-key-retrieve \
	--status-fd=1 --verify "$sig" "$out" 2>/dev/null)"; then
	rm -f -- "$sig"
	echo "build.sh: a assinatura gerada não passou na verificação." >&2
	exit 1
fi
valid_line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status" | head -n1 || true)"
read -r -a valid_fields <<<"$valid_line"
signing_fingerprint="${valid_fields[11]:-${valid_fields[2]:-}}"
if [[ "$signing_fingerprint" != "$fingerprint" ]] ||
	grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED)' <<<"$status"; then
	rm -f -- "$sig"
	echo "build.sh: assinatura não corresponde à chave pública de release." >&2
	exit 1
fi

echo "signed: $sig"
echo "release fingerprint: $fingerprint"
