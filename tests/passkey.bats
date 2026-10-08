#!/usr/bin/env bats
# npass-passkey: armazenamento de passkeys (Fido/.map + Fido/*.gpg), integridade,
# helper assinado e instalação do daemon Rust apenas quando selecionado.

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export PROJECT_DIR="$BATS_TEST_DIRNAME/.."
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export NPASS_HELPERS_DIR="$BATS_TEST_TMPDIR/helpers"
	export NPASS_PASSKEY_GIT=0
	unset NPASS_GPG NPASS_BIN
	npass_test_install_ext npass-passkey
	"$NPASS" init pessoal "$FPR" >/dev/null
	FIDO="$NPASS_STORE/pessoal/Fido"
	CRED="$(printf 'cbor-secreto-1234567890' | base64 -w0)"
}

pk() { "$NPASS" passkey "$@"; }
store() { printf '%s' "${4:-$CRED}" | "$NPASS" passkey store "$1" "$2" "$3"; }
only_blob() { ls "$FIDO"/*.gpg | head -n1; }

# --- armazenamento e índice -----------------------------------------------------------

@test "store grava blob opaco, índice 0600 e imprime o nome do blob" {
	run store pessoal github.com ana
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9a-f]{32}\.gpg$ ]]
	[ -f "$FIDO/$output" ]
	[ "$(stat -c %a "$FIDO/.map")" = 600 ]
	[ "$(stat -c %a "$FIDO/$output")" = 600 ]
	[ "$(stat -c %a "$FIDO")" = 700 ]
	[ -e "$FIDO/.map.lock" ]
	[ "$(sed -n 1p "$FIDO/.map")" = "# npass-fido-map-v2" ]
	[ "$(sed -n 2p "$FIDO/.map")" = $'# rp_id\tlogin\tblob' ]
	[ "$(sed -n 3p "$FIDO/.map")" = $'github.com\tana\t'"$output" ]
}

@test "o blob tem cabeçalho público assinado e a credencial só existe cifrada" {
	b="$(store pessoal github.com ana)"
	[ "$(sed -n 1p "$FIDO/$b")" = "NPASS-FIDO-BLOB-V1" ]
	[ "$(sed -n 2p "$FIDO/$b")" = $'rp_id\tgithub.com' ]
	[ "$(sed -n 3p "$FIDO/$b")" = $'login\tana' ]
	[[ "$(sed -n 4p "$FIDO/$b")" =~ ^payload-sha256$'\t'[0-9a-f]{64}$ ]]
	[[ "$(sed -n 5p "$FIDO/$b")" == signature-b64$'\t'* ]]
	[ "$(sed -n 6p "$FIDO/$b")" = "-----BEGIN PGP MESSAGE-----" ]
	run grep -rl -e "$CRED" -e "cbor-secreto" "$FIDO"
	[ "$status" -ne 0 ]
}

@test "o índice não é chave única: várias passkeys para o mesmo RP e login" {
	b1="$(store pessoal github.com ana)"
	b2="$(store pessoal github.com ana)"
	[ "$b1" != "$b2" ]
	run pk list pessoal github.com ana
	[ "$(wc -l <<<"$output")" -eq 2 ]
}

@test "list filtra por RP e login" {
	store pessoal github.com pessoal >/dev/null
	store pessoal github.com trabalho >/dev/null
	store pessoal gitlab.com pessoal >/dev/null
	run pk list pessoal
	[ "$(wc -l <<<"$output")" -eq 3 ]
	run pk list pessoal github.com
	[ "$(wc -l <<<"$output")" -eq 2 ]
	run pk list pessoal github.com trabalho
	[ "$(wc -l <<<"$output")" -eq 1 ]
	[[ "$output" == github.com$'\t'trabalho$'\t'* ]]
	run pk list pessoal nada.com
	[ -z "$output" ]
}

@test "load verifica e devolve a credencial; store rejeita campos e base64 inválidos" {
	b="$(store pessoal github.com ana)"
	run pk load pessoal "$b"
	[ "$status" -eq 0 ]
	[ "$output" = "$CRED" ]
	run pk load pessoal "${b%.gpg}"
	[ "$output" = "$CRED" ]
	run store pessoal $'rp\tx' ana
	[ "$status" -ne 0 ]
	run store pessoal github.com ""
	[ "$status" -ne 0 ]
	run store pessoal github.com ana "isto não é base64!"
	[ "$status" -ne 0 ]
	run pk load pessoal ../../etc/passwd
	[ "$status" -ne 0 ]
}

@test "rm apaga o blob e a entrada do índice" {
	b="$(store pessoal github.com ana)"
	store pessoal gitlab.com ana >/dev/null
	run pk rm pessoal "$b"
	[ "$status" -eq 0 ]
	[ ! -e "$FIDO/$b" ]
	run pk list pessoal
	[ "$(wc -l <<<"$output")" -eq 1 ]
	run pk rm pessoal "$b"
	[ "$status" -ne 0 ]
}

@test "se o índice não puder ser atualizado, o blob novo é revertido" {
	store pessoal github.com ana >/dev/null
	rm -f "$FIDO/.map"
	mkdir "$FIDO/.map"
	run store pessoal gitlab.com ana
	[ "$status" -ne 0 ]
	[ "$(ls "$FIDO"/*.gpg | wc -l)" -eq 1 ]
}

# --- integridade -----------------------------------------------------------------------

@test "verify: store íntegro (inclui --deep)" {
	store pessoal github.com ana >/dev/null
	store pessoal github.com bia "$(printf 'outra-credencial' | base64 -w0)" >/dev/null
	run pk verify pessoal --deep
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 sem problemas, 0 problema"* ]]
}

@test "blob com rp_id/login trocado no cabeçalho é rejeitado" {
	b="$(store pessoal github.com ana)"
	sed -i '2s/github.com/evil.com/' "$FIDO/$b"
	run pk load pessoal "$b"
	[ "$status" -ne 0 ]
	[[ "$output" == *"assinatura"* ]]
	run pk verify pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"PROBLEMA ASSINATURA"* ]]
}

@test "blob com payload adulterado é rejeitado pelo hash" {
	b="$(store pessoal github.com ana)"
	sed -i '8s/./X/' "$FIDO/$b"
	run pk load pessoal "$b"
	[ "$status" -ne 0 ]
	[[ "$output" == *"hash"* ]]
	run pk verify pessoal
	[[ "$output" == *"PROBLEMA HASH"* ]]
}

@test "blob assinado por chave não autorizada é rejeitado, mesmo com assinatura válida" {
	b="$(store pessoal github.com ana)"
	# o atacante é conhecido do chaveiro (só a pública), mas não está no .gpg-id
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --export | gpg --import 2>/dev/null
	head -n4 "$FIDO/$b" >"$BATS_TEST_TMPDIR/meta"
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --batch --yes -q --detach-sign -o "$BATS_TEST_TMPDIR/sig" "$BATS_TEST_TMPDIR/meta"
	{
		cat "$BATS_TEST_TMPDIR/meta"
		printf 'signature-b64\t%s\n' "$(base64 -w0 <"$BATS_TEST_TMPDIR/sig")"
		tail -n +6 "$FIDO/$b"
	} >"$BATS_TEST_TMPDIR/forjado"
	cp "$BATS_TEST_TMPDIR/forjado" "$FIDO/$b"
	run pk load pessoal "$b"
	[ "$status" -ne 0 ]
	[[ "$output" == *"não autorizada"* ]]
	run pk verify pessoal
	[[ "$output" == *"PROBLEMA NAO_AUTORIZADA"* ]]
}

@test "verify detecta órfão, entrada pendurada, duplicata e permissão errada" {
	b="$(store pessoal github.com ana)"
	cp "$FIDO/$b" "$FIDO/copia.gpg"                 # órfão + payload duplicado
	printf 'x.com\ty\tfantasma.gpg\n' >>"$FIDO/.map" # entrada sem blob
	chmod 644 "$FIDO/.map"
	run pk verify pessoal --deep
	[ "$status" -ne 0 ]
	[[ "$output" == *"PROBLEMA ORFAO copia.gpg"* ]]
	[[ "$output" == *"PROBLEMA PENDURADO fantasma.gpg"* ]]
	[[ "$output" == *"PROBLEMA DUP_PAYLOAD "* ]]
	[[ "$output" == *"PROBLEMA DUP_CREDENCIAL "* ]]
	[[ "$output" == *"PROBLEMA PERMISSAO .map"* ]]
}

@test "o índice nunca é autoridade: entrada forjada no .map não faz o blob valer" {
	b="$(store pessoal github.com ana)"
	printf 'github.com\tana\t%s\n' "$b" >>"$FIDO/.map"
	run pk verify pessoal
	[[ "$output" == *"DUP_INDICE"* ]]
	run pk load pessoal "$b"                         # load nem consulta o índice
	[ "$status" -eq 0 ]
}

@test "rebuild-index reconstrói só dos blobs verificados e pula os adulterados" {
	b1="$(store pessoal github.com ana)"
	b2="$(store pessoal gitlab.com bia)"
	b3="$(store pessoal evil.com zed)"
	sed -i '2s/evil.com/outro.com/' "$FIDO/$b3"
	rm "$FIDO/.map"
	[ -z "$(pk list pessoal 2>/dev/null)" ]
	run pk rebuild-index pessoal
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 entrada(s), 1 blob(s) rejeitado(s)"* ]]
	[ "$(stat -c %a "$FIDO/.map")" = 600 ]
	run pk list pessoal
	[ "$(wc -l <<<"$output")" -eq 2 ]
	[[ "$output" == *"$b1"* && "$output" == *"$b2"* && "$output" != *"$b3"* ]]
}

@test "rebuild-index conserta índice corrompido" {
	store pessoal github.com ana >/dev/null
	printf 'lixo\n' >"$FIDO/.map"
	run pk list pessoal
	[ "$status" -ne 0 ]
	run pk rebuild-index pessoal
	[ "$status" -eq 0 ]
	run pk verify pessoal
	[ "$status" -eq 0 ]
}

# --- helper: localizar, validar, executar -----------------------------------------------

fake_helper() {
	mkdir -p -m 700 "$NPASS_HELPERS_DIR"
	printf '#!/bin/sh\necho "helper-rodou: $*"\n' >"$NPASS_HELPERS_DIR/npass-passkeyd"
	chmod 755 "$NPASS_HELPERS_DIR/npass-passkeyd"
}

@test "serve recusa helper ausente, sem assinatura ou sem selo" {
	run pk serve pessoal
	[ "$status" -ne 0 ]
	fake_helper
	run pk serve pessoal
	[[ "$output" == *"sem assinatura"* ]]
	gpg --batch --yes -q -u "$FPR" --detach-sign -o "$NPASS_HELPERS_DIR/npass-passkeyd.sig" "$NPASS_HELPERS_DIR/npass-passkeyd"
	run pk serve pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"stamp"* ]]
}

@test "seal + serve: só executa o helper válido, com o --id da identidade" {
	fake_helper
	run pk seal "$FPR"
	[ "$status" -eq 0 ]
	run pk serve pessoal --confirm-cmd true
	[ "$status" -eq 0 ]
	[ "$output" = "helper-rodou: --id pessoal --confirm-cmd true" ]
}

@test "serve recusa binário adulterado, com assinatura de chave alheia e binário velho assinado por você" {
	fake_helper
	pk seal "$FPR" >/dev/null
	h="$NPASS_HELPERS_DIR/npass-passkeyd"
	cp "$h" "$BATS_TEST_TMPDIR/bom"
	# adulterado depois do selo
	echo '# x' >>"$h"
	run pk serve pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"assinatura inválida"* ]]
	# assinado pelo atacante
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --batch --yes -q --detach-sign -o "$h.sig" "$h"
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --export | gpg --import 2>/dev/null
	run pk serve pessoal
	[[ "$output" == *"não é sua"* ]]
	# binário velho: assinatura SUA válida, mas o selo não o conhece
	gpg --batch --yes -q -u "$FPR" --detach-sign -o "$h.sig" "$h"
	run pk serve pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"binário antigo ou adulterado"* ]]
	# e um link simbólico nunca passa
	rm "$h" "$h.sig"
	ln -s "$BATS_TEST_TMPDIR/bom" "$h"
	run pk serve pessoal
	[[ "$output" == *"link simbólico"* ]]
}

@test "serve recusa helper selado para outra versão da extensão" {
	fake_helper
	pk seal "$FPR" >/dev/null
	echo '# versão nova' >>"$NPASS_EXTENSIONS_DIR/npass-passkey"
	"$NPASS" extension sign "$NPASS_EXTENSIONS_DIR/npass-passkey" "$FPR" >/dev/null
	run pk serve pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"outra versão desta extensão"* ]]
}

@test "serve recusa diretório de helpers gravável por outros" {
	fake_helper
	pk seal "$FPR" >/dev/null
	chmod 777 "$NPASS_HELPERS_DIR"
	run pk serve pessoal
	[ "$status" -ne 0 ]
	[[ "$output" == *"gravável"* ]]
}

# --- instalação -------------------------------------------------------------------------

# cargo de mentira no PATH: registra a chamada e (se pedido) produz o helper.
fake_cargo() {
	mkdir -p "$BATS_TEST_TMPDIR/fakebin"
	cat >"$BATS_TEST_TMPDIR/fakebin/cargo" <<EOS
#!/bin/sh
echo "\$*" >>"$BATS_TEST_TMPDIR/cargo.log"
[ "$1" = fail ] && exit 1
case "\$*" in *--locked*) ;; *) exit 3 ;; esac
[ -n "\$FAKE_CARGO_FAIL" ] && exit 1
mkdir -p "$PROJECT_DIR/passkey/target/release"
printf '#!/bin/sh\necho helper-novo\n' >"$PROJECT_DIR/passkey/target/release/npass-passkeyd"
chmod 755 "$PROJECT_DIR/passkey/target/release/npass-passkeyd"
EOS
	chmod +x "$BATS_TEST_TMPDIR/fakebin/cargo"
}

# respostas: ver extensões, e uma por candidata na ordem do glob
# (audit, clip-x11, import, passkey, wclip)
run_install() {
	local answers="$1"
	PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" bash -c "printf '$answers' | '$PROJECT_DIR/install.sh' --prefix='$BATS_TEST_TMPDIR/prefix' --extensions --sign-key='$FPR'"
}

@test "instalar outras extensões NÃO executa o cargo" {
	fake_cargo
	run run_install 's\nn\nn\ns\nn\nn\n'   # só npass-import
	[ "$status" -eq 0 ]
	[ -x "$NPASS_EXTENSIONS_DIR/npass-import" ]
	[ ! -e "$BATS_TEST_TMPDIR/cargo.log" ]
	[ ! -e "$NPASS_HELPERS_DIR/npass-passkeyd" ]
}

@test "escolher npass-passkey compila o código atual, instala, assina e sela o helper" {
	fake_cargo
	rm -rf "$PROJECT_DIR/passkey/target/release/npass-passkeyd"
	# um binário velho largado em bin/ jamais é usado
	mkdir -p "$PROJECT_DIR/bin" && printf 'VELHO' >"$PROJECT_DIR/bin/npass-passkeyd"
	run run_install 's\nn\nn\nn\ns\nn\n'
	[ "$status" -eq 0 ]
	grep -q -- '--release --locked --manifest-path passkey/Cargo.toml' "$BATS_TEST_TMPDIR/cargo.log"
	[ -f "$NPASS_EXTENSIONS_DIR/npass-passkey.sig" ]
	[ -x "$NPASS_HELPERS_DIR/npass-passkeyd" ]
	[ -f "$NPASS_HELPERS_DIR/npass-passkeyd.sig" ]
	[ -f "$NPASS_HELPERS_DIR/npass-passkeyd.stamp.sig" ]
	run "$NPASS_HELPERS_DIR/npass-passkeyd"
	[ "$output" = "helper-novo" ]
	[ ! -e "$PROJECT_DIR/bin/npass-passkeyd" ] || [ "$(cat "$PROJECT_DIR/bin/npass-passkeyd")" != VELHO ]
	# e o ciclo fecha: serve aceita o que o instalador selou
	run pk serve pessoal
	[ "$output" = "helper-novo" ] || [ "$output" = "helper-rodou: --id pessoal" ] || [[ "$output" == *helper-novo* ]]
	rm -rf "$PROJECT_DIR/passkey/target/release/npass-passkeyd"
}

@test "se o cargo falhar, a extensão não fica instalada e nenhum binário velho é aproveitado" {
	fake_cargo
	mkdir -p "$PROJECT_DIR/passkey/target/release"
	printf 'VELHO' >"$PROJECT_DIR/passkey/target/release/npass-passkeyd"; chmod 755 "$PROJECT_DIR/passkey/target/release/npass-passkeyd"
	export FAKE_CARGO_FAIL=1
	rm -f "$NPASS_EXTENSIONS_DIR/npass-passkey" "$NPASS_EXTENSIONS_DIR/npass-passkey.sig"
	run run_install 's\nn\nn\nn\ns\nn\n'
	[ "$status" -eq 0 ]
	[[ "$output" == *"compilação"*"falhou"* ]]
	[ ! -e "$NPASS_EXTENSIONS_DIR/npass-passkey" ]
	[ ! -e "$NPASS_HELPERS_DIR/npass-passkeyd" ]
	[ ! -e "$PROJECT_DIR/passkey/target/release/npass-passkeyd" ]
}

# --- daemon Rust: ciclo WebAuthn completo contra o npass real -----------------------------

@test "daemon: registro + autenticação CTAP2 (assinatura ES256 verificada) guardando em Fido/*.gpg" {
	command -v cargo >/dev/null || skip "cargo não encontrado"
	"$NPASS" init pinid "$FPR" >/dev/null
	export NPASS_E2E_BIN="$NPASS" NPASS_E2E_ID=pessoal NPASS_E2E_PIN_ID=pinid
	run cargo test --manifest-path "$PROJECT_DIR/passkey/Cargo.toml" --locked --test e2e
	[ "$status" -eq 0 ] || { echo "$output" >&2; false; }
	run pk list pessoal site.test
	[ "$(wc -l <<<"$output")" -eq 2 ]
	run pk verify pessoal --deep
	[ "$status" -eq 0 ]
	# a política/PIN foram exercitados no npass real, só dentro da identidade "pinid"
	run pk pin status pinid
	[[ "$output" == *"policy nunca"* && "$output" == *"set 1"* ]]
	run pk pin status pessoal
	[[ "$output" == *"set 0"* ]]
}

# --- PIN e política de exigência (por identidade, em Fido/) --------------------------------

pin_set() { pk pin set "$1" --new-pin-fd 3 3<<<"$2"; }
pin_verify() { pk pin verify "$1" <<<"$2"; }

@test "pin status padrão: opcional, sem PIN, 5 tentativas" {
	run pk pin status pessoal
	[ "$status" -eq 0 ]
	[ "$output" = $'policy opcional\nset 0\ntries-left 5\nblocked 0' ]
}

@test "pin set: arquivo cifrado 0600 + contador 0600; o PIN não aparece em claro" {
	run pin_set pessoal "Abc12345"
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$FIDO/.pin.gpg")" = 600 ]
	[ "$(stat -c %a "$FIDO/.pin-tries")" = 600 ]
	[ "$(cat "$FIDO/.pin-tries")" = 0 ]
	run grep -rl "Abc12345" "$FIDO"
	[ "$status" -ne 0 ]
	run pin_set pessoal "Outro1234"
	[ "$status" -ne 0 ]
	[[ "$output" == *"pin change"* ]]
}

@test "pin: alfanumérico de 4 a 64 caracteres" {
	run pin_set pessoal "abc"
	[ "$status" -ne 0 ]
	run pin_set pessoal "$(printf 'a%.0s' {1..65})"
	[ "$status" -ne 0 ]
	run pin_set pessoal "abc def"
	[ "$status" -ne 0 ]
	run pin_set pessoal "ab-c#d1"
	[ "$status" -ne 0 ]
	run pin_set pessoal "ação1234"
	[ "$status" -ne 0 ]
	[ ! -e "$FIDO/.pin.gpg" ]
	run pin_set pessoal "$(printf 'Z9%.0s' {1..32})"      # 64
	[ "$status" -eq 0 ]
	run pin_verify pessoal "$(printf 'Z9%.0s' {1..32})"
	[ "$status" -eq 0 ]
}

@test "verify: acerto passa; 5 erros bloqueiam e nem o PIN certo vale depois" {
	pin_set pessoal "Abc12345"
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 0 ]
	for n in 4 3 2 1; do
		run pin_verify pessoal "errado$n"
		[ "$status" -eq 10 ]
		[[ "$output" == *"tries-left $n"* ]]
	done
	run pin_verify pessoal "errado0"
	[ "$status" -eq 10 ]
	[[ "$output" == *"BLOQUEADO"* ]]
	[ "$(cat "$FIDO/.pin-tries")" = 5 ]
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 11 ]
	run pk pin status pessoal
	[[ "$output" == *"blocked 1"* && "$output" == *"tries-left 0"* ]]
}

@test "acerto zera o contador de erros" {
	pin_set pessoal "Abc12345"
	pin_verify pessoal errado1 || true
	pin_verify pessoal errado2 || true
	[ "$(cat "$FIDO/.pin-tries")" = 2 ]
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 0 ]
	[ "$(cat "$FIDO/.pin-tries")" = 0 ]
}

@test "verify sem PIN definido devolve 12" {
	run pin_verify pessoal qualquer1
	[ "$status" -eq 12 ]
	pk pin policy pessoal opcional >/dev/null
	run pin_verify pessoal qualquer1
	[ "$status" -eq 12 ]
}

@test "troca de PIN exige o PIN atual: errado falha e conta; certo troca" {
	pin_set pessoal "Abc12345"
	run pk pin change pessoal --pin-fd 3 --new-pin-fd 4 3<<<"errado99" 4<<<"Novo98765"
	[ "$status" -eq 10 ]
	[ "$(cat "$FIDO/.pin-tries")" = 1 ]
	run pin_verify pessoal "Novo98765"
	[ "$status" -eq 10 ]                                  # não trocou
	run pk pin change pessoal --pin-fd 3 --new-pin-fd 4 3<<<"Abc12345" 4<<<"Novo98765"
	[ "$status" -eq 0 ]
	[ "$(cat "$FIDO/.pin-tries")" = 0 ]
	run pin_verify pessoal "Novo98765"
	[ "$status" -eq 0 ]
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 10 ]
}

@test "troca de PIN pela senha da chave GPG (--gpg) mesmo bloqueado, e restaura as tentativas" {
	pin_set pessoal "Abc12345"
	for n in 1 2 3 4 5; do pin_verify pessoal "errado$n" || true; done
	run pk pin change pessoal --pin-fd 3 --new-pin-fd 4 3<<<"Abc12345" 4<<<"Novo98765"
	[ "$status" -eq 11 ]                                  # PIN certo, mas bloqueado
	run pk pin change pessoal --gpg --new-pin-fd 4 4<<<"Novo98765"
	[ "$status" -eq 0 ]
	run pk pin status pessoal
	[[ "$output" == *"blocked 0"* && "$output" == *"tries-left 5"* ]]
	run pin_verify pessoal "Novo98765"
	[ "$status" -eq 0 ]
}

@test "troca de PIN valida o formato do PIN novo" {
	pin_set pessoal "Abc12345"
	run pk pin change pessoal --pin-fd 3 --new-pin-fd 4 3<<<"Abc12345" 4<<<"ab"
	[ "$status" -ne 0 ]
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 0 ]
}

@test "política: padrão opcional; mudar exige PIN atual ou --gpg quando há PIN" {
	run pk pin policy pessoal
	[ "$output" = opcional ]
	run pk pin policy pessoal talvez
	[ "$status" -ne 0 ]
	run pk pin policy pessoal requerido                    # sem PIN: livre (mas avisa)
	[ "$status" -eq 0 ]
	[[ "$output" == *"NEGADA"* ]]
	run pk pin policy pessoal
	[ "$output" = requerido ]
	pk pin policy pessoal nunca >/dev/null
	pin_set pessoal "Abc12345"
	run pk pin policy pessoal opcional --pin-fd 3 3<<<"errado99"
	[ "$status" -eq 10 ]
	run pk pin policy pessoal
	[ "$output" = nunca ]                                  # PIN errado não mudou nada
	run pk pin policy pessoal opcional --pin-fd 3 3<<<"Abc12345"
	[ "$status" -eq 0 ]
	run pk pin policy pessoal requerido --gpg
	[ "$status" -eq 0 ]
	run pk pin status pessoal
	[[ "$output" == *"policy requerido"* && "$output" == *"set 1"* ]]
	run pk pin policy pessoal nunca --pin-fd 3 3<<<"Abc12345"
	[ "$status" -eq 0 ]
}

@test "a política e o PIN sobrevivem um ao outro (policy não apaga o PIN)" {
	pin_set pessoal "Abc12345"
	pk pin policy pessoal requerido --pin-fd 3 3<<<"Abc12345" >/dev/null
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 0 ]
	pk pin change pessoal --pin-fd 3 --new-pin-fd 4 3<<<"Abc12345" 4<<<"Novo98765" >/dev/null
	run pk pin policy pessoal
	[ "$output" = requerido ]
}

@test "registro de PIN trocado por um cifrado sem assinatura é recusado (bloqueado)" {
	pin_set pessoal "Abc12345"
	printf 'NPASS-FIDO-PIN-V1\npolicy\tnunca\n' | gpg --batch --yes -q --trust-model always --armor -e -r "$FPR" -o "$FIDO/.pin.gpg"
	run pk pin status pessoal
	[[ "$output" == *"policy requerido"* && "$output" == *"blocked 1"* && "$output" == *"tampered 1"* ]]
	run pin_verify pessoal "Abc12345"
	[ "$status" -eq 11 ]
}

@test "registro de PIN assinado por chave não autorizada é recusado" {
	pin_set pessoal "Abc12345"
	GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --export | gpg --import 2>/dev/null
	printf 'NPASS-FIDO-PIN-V1\npolicy\tnunca\n' \
		| GNUPGHOME="$ATACANTE_GNUPGHOME" gpg --batch --yes -q --sign -o "$BATS_TEST_TMPDIR/s.bin"
	gpg --batch --yes -q --trust-model always --armor -e -r "$FPR" -o "$FIDO/.pin.gpg" "$BATS_TEST_TMPDIR/s.bin"
	run pk pin status pessoal
	[[ "$output" == *"blocked 1"* && "$output" == *"tampered 1"* ]]
}

@test "apagar o registro de PIN deixando o contador não rebaixa a segurança; --gpg recupera" {
	pin_set pessoal "Abc12345"
	pk pin policy pessoal requerido --gpg >/dev/null
	rm "$FIDO/.pin.gpg"
	run pk pin status pessoal
	[[ "$output" == *"blocked 1"* && "$output" == *"tampered 1"* ]]
	run pin_set pessoal "Novo98765"
	[ "$status" -ne 0 ]
	run pk pin set pessoal --gpg --new-pin-fd 3 3<<<"Novo98765"
	[ "$status" -eq 0 ]
	run pin_verify pessoal "Novo98765"
	[ "$status" -eq 0 ]
}

@test "cada identidade tem o seu PIN, política e contador" {
	"$NPASS" init trabalho "$FPR" >/dev/null
	pin_set pessoal "Pessoal123"
	pin_set trabalho "Trabalho456"
	pk pin policy trabalho requerido --pin-fd 3 3<<<"Trabalho456" >/dev/null
	for n in 1 2 3 4 5; do pin_verify pessoal "errado$n" || true; done
	run pk pin status pessoal
	[[ "$output" == *"blocked 1"* ]]
	run pk pin status trabalho
	[[ "$output" == *"policy requerido"* && "$output" == *"blocked 0"* && "$output" == *"tries-left 5"* ]]
	run pin_verify trabalho "Pessoal123"                  # o PIN de uma não abre a outra
	[ "$status" -eq 10 ]
	run pin_verify trabalho "Trabalho456"
	[ "$status" -eq 0 ]
	[ -e "$NPASS_STORE/trabalho/Fido/.pin-tries" ] && [ -e "$NPASS_STORE/pessoal/Fido/.pin-tries" ]
}

@test "git: o registro de PIN é versionado; o contador de erros nunca" {
	export NPASS_PASSKEY_GIT=1
	git -C "$NPASS_STORE" init -q
	git -C "$NPASS_STORE" config user.email t@t
	git -C "$NPASS_STORE" config user.name t
	pin_set pessoal "Abc12345"
	pin_verify pessoal errado1 || true
	store pessoal github.com ana >/dev/null
	run git -C "$NPASS_STORE" ls-files
	[[ "$output" == *"pessoal/Fido/.pin.gpg"* ]]
	[[ "$output" != *".pin-tries"* && "$output" != *".map.lock"* ]]
	run git -C "$NPASS_STORE" log --format=%s
	[[ "$output" != *"Abc12345"* && "$output" != *"errado"* ]]
}

@test "o daemon não tem --auto-approve" {
	command -v cargo >/dev/null || skip "cargo não encontrado"
	run cargo test --manifest-path "$PROJECT_DIR/passkey/Cargo.toml" --locked --test cli
	[ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
