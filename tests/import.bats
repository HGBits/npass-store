#!/usr/bin/env bats
# Extensao npass-import (extensions/npass-import). Os fixtures sao sinteticos,
# escritos a partir do formato documentado de cada gerenciador: servem de
# regressao do parser, NAO substituem testar com um export real (sanitizado).

setup() {
	export GNUPGHOME="$BATS_TEST_DIRNAME/gnupg_test"
	load helper
	npass_test_keys || return 1
	command -v python3 >/dev/null || skip "python3 nao instalado"
	export NPASS_STORE="$BATS_TEST_TMPDIR/store"
	export NPASS="$BATS_TEST_DIRNAME/../bin/npass"
	export NPASS_EXTENSIONS_DIR="$BATS_TEST_TMPDIR/ext"
	export NPASS_ENABLE_EXTENSIONS=1
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	"$NPASS" extension install "$BATS_TEST_DIRNAME/../extensions/npass-import" "$FPR" >/dev/null
	"$NPASS" init HG "$FPR" >/dev/null
	F="$BATS_TEST_TMPDIR/in"
}

# --- geral ---------------------------------------------------------------------

@test "import --list mostra os formatos, incluindo pass e pass-secrets" {
	run "$NPASS" import --list
	[ "$status" -eq 0 ]
	for f in csv bitwarden keepassxc firefox chrome lastpass 1password aegis andotp pass pass-secrets; do
		[[ "$output" == *"$f"* ]]
	done
}

@test "com extensoes desligadas (padrao) npass import e comando desconhecido" {
	NPASS_ENABLE_EXTENSIONS=0 run "$NPASS" import --list
	[ "$status" -ne 0 ]
	[[ "$output" == *"comando desconhecido"* ]]
}

@test "sem argumentos: uso e codigo 2; formato desconhecido: codigo 2" {
	run "$NPASS" import
	[ "$status" -eq 2 ]
	[[ "$output" == *"uso:"* ]]
	run "$NPASS" import csv HG
	[ "$status" -eq 2 ]
	run "$NPASS" import nao-existe HG "$F"
	[ "$status" -eq 2 ]
}

@test "NPASS_LANG=en troca as mensagens da extensao para ingles" {
	NPASS_LANG=en run "$NPASS" import
	[[ "$output" == *"usage:"* ]]
}

@test "identidade inexistente falha citando a identidade" {
	printf 'a,b\n' >"$F.csv"
	run "$NPASS" import csv NAOEXISTE "$F.csv" --cols 'title,password'
	[ "$status" -ne 0 ]
	[[ "$output" == *"NAOEXISTE"* ]]
}

# --- csv generico ----------------------------------------------------------------

@test "csv generico: --cols, titulo vindo do host da URL, conteudo no formato pass" {
	printf 'https://www.a.com,alice,ignorado,s3cr3t\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'url,login,,password'
	[ "$status" -eq 0 ]
	run "$NPASS" show HG a.com
	[ "$output" = $'s3cr3t\nlogin: alice\nurl: https://www.a.com' ]
}

@test "csv generico: coluna com nome desconhecido vira campo extra; --skip-header" {
	printf 'titulo,senha,pin\nBanco,pw,1234\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,password,pin' --skip-header
	run "$NPASS" show HG Banco
	[ "$output" = $'pw\npin: 1234' ]
}

@test "csv sem --cols falha com mensagem clara" {
	printf 'a,b\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv"
	[ "$status" -ne 0 ]
	[[ "$output" == *"--cols"* ]]
}

@test "campo de 200 KB em notas nao estoura o limite do csv" {
	printf 'Grande,pw,%s\n' "$(head -c 200000 /dev/zero | tr '\0' a)" >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password,notes'
	[ "$status" -eq 0 ]
	[ "$("$NPASS" show HG Grande | wc -c)" -ge 200000 ]
}

# --- formatos ---------------------------------------------------------------------

@test "keepassxc: aspas, virgulas e notas em varias linhas; titulos repetidos viram titulo/login" {
	cat >"$F.csv" <<'CSV'
"Group","Title","Username","Password","URL","Notes","TOTP"
"Root/Email","Gmail","nat@x.com","p@ss,word","https://mail.google.com","linha 1
linha 2, com ""aspas""","JBSWY3DPEHPK3PXP"
"Root/Email","Gmail","outra@x.com","s3nh4","https://mail.google.com","",""
"Banco","Itaú","12345","numerica","","",""
CSV
	run "$NPASS" import keepassxc HG "$F.csv"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG "Root/Email/Gmail/nat@x.com"
	[ "$output" = $'p@ss,word\nlogin: nat@x.com\nurl: https://mail.google.com\notpauth://totp/Gmail:nat%40x.com?secret=JBSWY3DPEHPK3PXP&issuer=Gmail\n\nlinha 1\nlinha 2, com "aspas"' ]
	run "$NPASS" show HG "Root/Email/Gmail/outra@x.com"
	[ "${output%%$'\n'*}" = "s3nh4" ]
	run "$NPASS" show HG "Banco/Itaú"
	[ "${output%%$'\n'*}" = "numerica" ]
}

@test "bitwarden csv: pasta aninhada, varias URLs, campos personalizados, TOTP e nota segura" {
	cat >"$F.csv" <<'CSV'
folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
Trabalho/Dev,,login,GitHub,"n1
n2",Pergunta: Rex,0,"https://github.com
https://gist.github.com",alice,pw1,JBSWY3DPEHPK3PXP
Trabalho/Dev,,login,GitHub,,,0,https://github.com,bob,pw2,
,,note,Nota solta,so texto,,0,,,,
CSV
	run "$NPASS" import bitwarden HG "$F.csv"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG "Trabalho/Dev/GitHub/alice"
	[ "${output%%$'\n'*}" = "pw1" ]
	[[ "$output" == *$'\nlogin: alice\n'* ]]
	[[ "$output" == *"url: https://github.com"* ]]
	[[ "$output" == *"url-2: https://gist.github.com"* ]]
	[[ "$output" == *"Pergunta: Rex"* ]]
	[[ "$output" == *"otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"* ]]
	[[ "$output" == *$'\n\nn1\nn2' ]]
	run "$NPASS" show HG "Trabalho/Dev/GitHub/bob"
	[ "${output%%$'\n'*}" = "pw2" ]
	run "$NPASS" show HG "Nota solta"
	[ "${output%%$'\n'*}" = "" ]
	[[ "$output" == *"so texto" ]]
}

@test "bitwarden json: pastas por id, campos, cartao e identidade viram campos" {
	cat >"$F.json" <<'JSON'
{"encrypted":false,"folders":[{"id":"f1","name":"Pessoal"}],"items":[
 {"id":"1","folderId":"f1","type":1,"name":"Site","notes":null,
  "fields":[{"name":"PIN","value":"1234","type":0}],
  "login":{"uris":[{"match":null,"uri":"https://site.com"}],"username":"u","password":"p","totp":"JBSWY3DPEHPK3PXP"}},
 {"id":"2","folderId":null,"type":3,"name":"Cartão","notes":null,
  "card":{"cardholderName":"N","number":"4111","code":"123"}}]}
JSON
	run "$NPASS" import bitwarden HG "$F.json"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG "Pessoal/Site"
	[ "${output%%$'\n'*}" = "p" ]
	[[ "$output" == *"PIN: 1234"* ]]
	[[ "$output" == *"otpauth://totp/Site:u?secret=JBSWY3DPEHPK3PXP&issuer=Site"* ]]
	run "$NPASS" show HG "Cartão"
	[ "${output%%$'\n'*}" = "" ]
	[[ "$output" == *"card-number: 4111"* ]]
	[[ "$output" == *"card-code: 123"* ]]
}

@test "bitwarden json criptografado e recusado com instrucao, sem gravar nada" {
	printf '{"encrypted":true,"encKeyValidation_DO_NOT_EDIT":"x","data":"y"}' >"$F.json"
	run "$NPASS" import bitwarden HG "$F.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"criptografado"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "firefox: titulo vem do host (sem www.)" {
	cat >"$F.csv" <<'CSV'
"url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
"https://www.exemplo.com","u1","p1","","https://www.exemplo.com","{g}","1","2","3"
CSV
	"$NPASS" import firefox HG "$F.csv"
	run "$NPASS" show HG exemplo.com
	[ "$output" = $'p1\nlogin: u1\nurl: https://www.exemplo.com' ]
}

@test "chrome: nome vira titulo e a nota vai depois de uma linha em branco" {
	printf 'name,url,username,password,note\nExemplo,https://ex.com,u,p,uma nota\n' >"$F.csv"
	"$NPASS" import chrome HG "$F.csv"
	run "$NPASS" show HG Exemplo
	[ "$output" = $'p\nlogin: u\nurl: https://ex.com\n\numa nota' ]
}

@test "lastpass: grupo com barra invertida vira pasta; http://sn (nota segura) nao vira URL" {
	cat >"$F.csv" <<'CSV'
url,username,password,totp,extra,name,grouping,fav
https://l.com,u,p,,,Loja,Pessoal\Compras,0
http://sn,,,,texto da nota,Cofre,,0
CSV
	run "$NPASS" import lastpass HG "$F.csv"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG "Pessoal/Compras/Loja"
	[ "${output%%$'\n'*}" = "p" ]
	run "$NPASS" show HG Cofre
	[[ "$output" != *"url:"* ]]
	[[ "$output" == *"texto da nota" ]]
}

@test "1password: a URI OTPAuth e mantida como esta" {
	cat >"$F.csv" <<'CSV'
Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
Banco,https://b.com,u,p,otpauth://totp/Banco:u?secret=JBSWY3DPEHPK3PXP&issuer=Banco,,,,nota
CSV
	"$NPASS" import 1password HG "$F.csv"
	run "$NPASS" show HG Banco
	[[ "$output" == *$'\notpauth://totp/Banco:u?secret=JBSWY3DPEHPK3PXP&issuer=Banco\n'* ]]
	[[ "$output" == *"nota" ]]
}

@test "aegis: TOTP e HOTP viram URIs otpauth legiveis pelo npass otp" {
	cat >"$F.json" <<'JSON'
{"version":1,"header":{"slots":null,"params":null},"db":{"version":2,"entries":[
 {"type":"totp","uuid":"x","name":"alice@x.com","issuer":"Exemplo","note":"","info":{"secret":"JBSWY3DPEHPK3PXP","algo":"SHA1","digits":6,"period":30}},
 {"type":"hotp","uuid":"y","name":"bob","issuer":"","note":"","info":{"secret":"GEZDGNBVGY3TQOJQ","algo":"SHA256","digits":8,"counter":5}}]}}
JSON
	run "$NPASS" import aegis HG "$F.json"
	[ "$status" -eq 0 ]
	run "$NPASS" otp uri HG Exemplo
	[ "$output" = "otpauth://totp/Exemplo:alice%40x.com?secret=JBSWY3DPEHPK3PXP&issuer=Exemplo" ]
	run "$NPASS" otp uri HG bob
	[ "$output" = "otpauth://hotp/bob?secret=GEZDGNBVGY3TQOJQ&algorithm=SHA256&digits=8&counter=5" ]
}

@test "aegis: o codigo TOTP gerado a partir do import tem 6 digitos" {
	command -v oathtool >/dev/null || skip "oathtool nao instalado"
	printf '{"db":{"entries":[{"type":"totp","name":"a","issuer":"Ex","info":{"secret":"JBSWY3DPEHPK3PXP","algo":"SHA1","digits":6,"period":30}}]}}' >"$F.json"
	"$NPASS" import aegis HG "$F.json"
	run "$NPASS" otp HG Ex
	[[ "$output" =~ ^[0-9]{6}$ ]]
}

@test "aegis com banco criptografado e recusado" {
	printf '{"version":1,"header":{"slots":[{}]},"db":"BASE64CIFRADA=="}' >"$F.json"
	run "$NPASS" import aegis HG "$F.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"criptografado"* ]]
}

@test "andotp: rotulo 'Emissor:conta' e separado; Steam vira campo bruto" {
	cat >"$F.json" <<'JSON'
[{"secret":"JBSWY3DPEHPK3PXP","issuer":"Exemplo","label":"Exemplo:alice@x.com","digits":6,"type":"TOTP","algorithm":"SHA1","period":30,"tags":[]},
 {"secret":"ABCDEFGHIJKLMNOP","issuer":"","label":"solo","digits":8,"type":"TOTP","algorithm":"SHA512","period":60},
 {"secret":"XXXX","issuer":"Steam","label":"g","type":"STEAM"}]
JSON
	"$NPASS" import andotp HG "$F.json"
	run "$NPASS" otp uri HG Exemplo
	[ "$output" = "otpauth://totp/Exemplo:alice%40x.com?secret=JBSWY3DPEHPK3PXP&issuer=Exemplo" ]
	run "$NPASS" otp uri HG solo
	[ "$output" = "otpauth://totp/solo?secret=ABCDEFGHIJKLMNOP&algorithm=SHA512&digits=8&period=60" ]
	run "$NPASS" show HG Steam
	[[ "$output" == *"otp-steam: XXXX"* ]]
}

@test "andotp criptografado (nao e uma lista JSON) e recusado" {
	printf '\x01\x02binario-aes' >"$F.json"
	run "$NPASS" import andotp HG "$F.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"criptografado"* ]]
}

# --- comportamento seguro --------------------------------------------------------

@test "-p coloca tudo sob um prefixo" {
	printf 'Site,pw\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,password' -p Importado/2026
	run "$NPASS" ls HG
	[[ "$output" == *"Importado/2026/Site"* ]]
}

@test "--dry-run lista o que faria, nao grava e nunca imprime segredos" {
	printf 'Site,s3cr3t-unico\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password' --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"+ Site"* ]]
	[[ "$output" != *"s3cr3t-unico"* ]]
	run "$NPASS" ls HG
	[[ "$output" == *"(vazio)"* ]]
}

@test "reimportar pula o que ja existe; sem -f a senha antiga e mantida; com -f e trocada" {
	printf 'Site,velha\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,password'
	printf 'Site,nova\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password'
	[[ "$output" == *"1 pulada"* ]]
	run "$NPASS" show HG Site
	[ "$output" = "velha" ]
	"$NPASS" import csv HG "$F.csv" --cols 'title,password' -f
	run "$NPASS" show HG Site
	[ "$output" = "nova" ]
}

@test "titulo e login repetidos dentro do proprio import ganham sufixo -2" {
	printf 'Dup,alice,pw1\nDup,alice,pw2\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,login,password'
	run "$NPASS" ls HG
	[[ "$output" == *"Dup/alice"* ]]
	[[ "$output" == *"Dup/alice-2"* ]]
}

@test "caminhos hostis sao neutralizados: .., barra no titulo, tab" {
	printf '../../etc,..,root,pw\n,a/b,,pw2\n' >"$F.csv"
	printf '"x\ty",,,pw3\n' >>"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'group,title,login,password'
	[ "$status" -eq 0 ]
	run "$NPASS" ls HG
	[[ "$output" == *"  etc/root"* ]]
	[[ "$output" == *"  a-b"* ]]
	[[ "$output" == *"  x y"* ]]
	[[ "$output" != *".."* ]]
}

@test "senha com quebra de linha nao e importada (erro, codigo 1); as demais entram" {
	printf 'Quebrada,"a\nb"\nBoa,ok\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password'
	[ "$status" -eq 1 ]
	[[ "$output" == *"quebra de linha"* ]]
	run "$NPASS" show HG Boa
	[ "$output" = "ok" ]
}

@test "entrada sem senha, OTP, notas nem campos e ignorada" {
	printf 'Vazia,\nBoa,ok\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password'
	[[ "$output" == *"1 ignorada"* ]]
	run "$NPASS" ls HG
	[[ "$output" != *"Vazia"* ]]
}

@test "importar e UM commit, e o log do git nao contem nomes logicos" {
	local antes; antes="$(git -C "$NPASS_STORE" rev-list --count HEAD)"
	printf 'ServicoSecreto,pw\nOutro,pw\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,password'
	[ "$(git -C "$NPASS_STORE" rev-list --count HEAD)" -eq $((antes + 1)) ]
	run git -C "$NPASS_STORE" log -p --all
	[[ "$output" != *"ServicoSecreto"* ]]
}

# --- origem ----------------------------------------------------------------------

@test "origem .gpg e decifrada em memoria (o texto em claro nao precisa existir)" {
	printf 'Site,pw-gpg\n' >"$F.csv"
	gpg --batch --yes --trust-model always -r "$FPR" -e -o "$F.csv.gpg" "$F.csv"
	rm -f "$F.csv"
	run "$NPASS" import csv HG "$F.csv.gpg" --cols 'title,password'
	[ "$status" -eq 0 ]
	run "$NPASS" show HG Site
	[ "$output" = "pw-gpg" ]
}

@test "origem '-' le do stdin" {
	run bash -c "printf 'Site,pw-stdin\n' | '$NPASS' import csv HG - --cols 'title,password'"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG Site
	[ "$output" = "pw-stdin" ]
}

@test "arquivo inexistente falha citando o arquivo" {
	run "$NPASS" import csv HG "$F.nao-existe" --cols 'title,password'
	[ "$status" -ne 0 ]
	[[ "$output" == *"nao-existe"* ]]
}

@test "encoding: latin-1 falha com dica em utf-8 e funciona com --encoding" {
	printf 'Caf\xe9,senha\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password'
	[ "$status" -ne 0 ]
	[[ "$output" == *"--encoding"* ]]
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password' --encoding latin-1
	[ "$status" -eq 0 ]
	run "$NPASS" ls HG
	[[ "$output" == *"Café"* ]]
}

@test "--delete-source apaga a origem so depois de importar sem erros" {
	printf 'Site,pw\n' >"$F.csv"
	"$NPASS" import csv HG "$F.csv" --cols 'title,password' --delete-source
	[ ! -e "$F.csv" ]
	printf 'Q,"a\nb"\n' >"$F.csv"
	run "$NPASS" import csv HG "$F.csv" --cols 'title,password' --delete-source
	[ "$status" -eq 1 ]
	[ -e "$F.csv" ]
}

# --- migrate / migrate-secrets incluidos ---------------------------------------------

@test "import pass delega ao migrate (store pass tradicional)" {
	local old="$BATS_TEST_TMPDIR/old"
	mkdir -p "$old/email"
	printf '%s\n' "$FPR" >"$old/.gpg-id"
	printf 'senhaGmail1\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$old/email/gmail.gpg"
	run "$NPASS" import pass HG "$old"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG email/gmail
	[ "$output" = "senhaGmail1" ]
}

@test "import pass-secrets delega ao migrate-secrets (caminho logico = codinome)" {
	local old="$BATS_TEST_TMPDIR/old-secrets"
	mkdir -p "$old/LOFT"
	printf '%s\n' "$FPR" >"$old/.gpg-id"
	printf 'LOFT/Zen = Amazon\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$old/.secrets.gpg"
	printf 'senhaAmazon\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$old/LOFT/Zen.gpg"
	run "$NPASS" import pass-secrets HG "$old"
	[ "$status" -eq 0 ]
	run "$NPASS" show HG LOFT/Zen
	[[ "$output" == "senhaAmazon"* ]]
}

@test "import pass repassa -f e --delete-source ao core; --dry-run e -p sao recusados" {
	local old="$BATS_TEST_TMPDIR/old"
	mkdir -p "$old"
	printf '%s\n' "$FPR" >"$old/.gpg-id"
	printf 'x\n' | gpg --batch --yes --trust-model always -r "$FPR" -e -o "$old/a.gpg"
	run "$NPASS" import pass HG "$old" --dry-run
	[ "$status" -eq 2 ]
	run "$NPASS" import pass HG "$old" -p Prefixo
	[ "$status" -eq 2 ]
	run "$NPASS" import pass HG "$old" --delete-source
	[ "$status" -eq 0 ]
	[ ! -e "$old/a.gpg" ]
}
