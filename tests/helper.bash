# Chaves GPG descartaveis para a suite de testes.
#
# Nada aqui depende de chaves ou fingerprints do ambiente de quem escreveu
# os testes: na primeira execucao os chaveiros tests/gnupg_test (2 chaves) e
# tests/gnupg_atacante (1 chave) sao gerados do zero, sem senha, e reusados
# nas seguintes. Ambos estao no .gitignore. Apague os diretorios para forcar
# a regeneracao.
#
# Uso, dentro de setup():
#   export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
#   load helper
#   npass_test_keys        # exporta FPR, FPR2 e ATACANTE_FPR

npass_test_gen() {
	local home="$1" uid
	shift
	mkdir -p -m 700 "$home"
	for uid in "$@"; do
		GNUPGHOME="$home" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
			--quick-gen-key "$uid" default default never >/dev/null 2>&1 || return 1
	done
	# primeira linha "fpr" de cada chave primaria, na ordem de criacao
	GNUPGHOME="$home" gpg --list-keys --with-colons 2>/dev/null \
		| awk -F: '$1=="pub"{p=1} $1=="fpr"&&p{print $10; p=0}' >"$home/.fprs"
}

npass_test_keys() {
	local t="$BATS_TEST_DIRNAME" lock="$BATS_TEST_DIRNAME/.keys.lock"
	command -v gpg >/dev/null || { echo "gpg nao encontrado" >&2; return 1; }
	(
		flock 9
		[[ -s "$t/gnupg_test/.fprs" && "$(wc -l <"$t/gnupg_test/.fprs")" -ge 2 ]] \
			|| { rm -rf "$t/gnupg_test"; npass_test_gen "$t/gnupg_test" "npass teste 1 <t1@npass.test>" "npass teste 2 <t2@npass.test>"; }
		[[ -s "$t/gnupg_atacante/.fprs" ]] \
			|| { rm -rf "$t/gnupg_atacante"; npass_test_gen "$t/gnupg_atacante" "npass atacante <atk@npass.test>"; }
	) 9>"$lock" || return 1
	export FPR FPR2 ATACANTE_FPR
	FPR="$(sed -n 1p "$t/gnupg_test/.fprs")"
	FPR2="$(sed -n 2p "$t/gnupg_test/.fprs")"
	ATACANTE_FPR="$(sed -n 1p "$t/gnupg_atacante/.fprs")"
	export ATACANTE_GNUPGHOME="$t/gnupg_atacante"
}

# npass_test_encr_keyid FPR -> ID longo (16 hex) da subchave de CIFRA da
# chave FPR, o mesmo que "gpg --list-packets" mostra num blob cifrado para ela.
npass_test_encr_keyid() {
	gpg --list-keys --with-colons "$1" 2>/dev/null \
		| awk -F: '$1=="sub" && $12 ~ /e/ {print toupper($5); exit}'
}
