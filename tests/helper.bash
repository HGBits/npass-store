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

# Garante um bin/npass atual. bin/ esta no .gitignore, entao num clone novo
# ele nao existe ate alguem rodar ./build.sh; sem isso, quase toda a suite
# falha com "bin/npass: Arquivo ou diretorio inexistente". Tambem reconstroi
# se algum lib/*.bash ou o build.sh for mais novo que o binario.
npass_test_build() {
	local root="$BATS_TEST_DIRNAME/.." bin="$BATS_TEST_DIRNAME/../bin/npass" stale=0 f
	if [[ ! -x "$bin" ]]; then
		stale=1
	else
		for f in "$root"/lib/*.bash "$root/build.sh"; do
			[[ "$f" -nt "$bin" ]] && { stale=1; break; }
		done
	fi
	((stale)) || return 0
	(
		flock 8
		# outro processo pode ter construido enquanto esperavamos o lock
		cd "$root" && bash build.sh >/dev/null 2>&1
	) 8>"$BATS_TEST_DIRNAME/.keys.lock"
	[[ -x "$bin" ]] || { echo "falha ao construir bin/npass (rode ./build.sh)" >&2; return 1; }
}

# Normaliza o ambiente para que a suite nao dependa do shell de quem roda:
# as mensagens (e varios asserts) sao em portugues, e um XDG_DATA_HOME ou
# NPASS_LANG exportados apontariam o npass para o store/idioma reais.
npass_test_env() {
	unset NPASS_LANG XDG_DATA_HOME LC_ALL LC_MESSAGES LANGUAGE
	export LANG=pt_BR.UTF-8
}

npass_test_keys() {
	local t="$BATS_TEST_DIRNAME" lock="$BATS_TEST_DIRNAME/.keys.lock"
	npass_test_env
	npass_test_build || return 1
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

# npass_test_install_ext ARQUIVO - instala extensions/ARQUIVO (sem o sufixo .bash,
# que o comando nao usa) em $NPASS_EXTENSIONS_DIR, assina com a chave de teste e liga
# as extensoes. Faz o que o install.sh faz quando voce aceita a extensao, sem prompt.
# Requer NPASS, FPR e NPASS_EXTENSIONS_DIR ja definidos (e GNUPGHOME).
npass_test_install_ext() {
	local src="$BATS_TEST_DIRNAME/../extensions/$1" name="${1%.bash}" dest
	dest="$NPASS_EXTENSIONS_DIR/$name"
	mkdir -p "$NPASS_EXTENSIONS_DIR"
	install -m 755 "$src" "$dest"
	"$NPASS" extension sign "$dest" "$FPR" >/dev/null || return 1
	export NPASS_ENABLE_EXTENSIONS=1
}
