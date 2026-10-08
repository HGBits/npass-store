# npass

Gerenciador de senhas para Linux baseado em **Bash + GPG**, com armazenamento por identidades, mapa lógico criptografado e blobs físicos com nomes opacos.

## Status

**Versão:** `2.0`
**Estado:** Pronto para uso
| **Instalação:** curl -sSL https://raw.githubusercontent.com/HGBits/npass-store/refs/heads/master/install.sh | bash

## Principais características

* Armazenamento criptografado com GPG.
* Separação por identidades.
* Mapa de caminhos lógicos criptografado.
* Blobs físicos com nomes aleatórios.
* Renomeação sem recriptografar o segredo.
* Movimentação entre identidades com recriptografia.
* Geração de senhas com `/dev/urandom`.
* Suporte a TOTP e HOTP.
* Clipboard nativo para Wayland.
* Integração opcional com Git.
* Assinatura opcional de `.gpg-id`.
* Sistema de extensões assinadas.
* Migração de stores `pass` e `pass-secrets-redesign`.

## Armazenamento

O caminho lógico de uma senha não é utilizado diretamente como nome de arquivo.

Por exemplo:

```text
email/gmail
```

pode ser armazenado como:

```text
pessoal/
├── .gpg-id
├── .map.gpg
└── blobs/
    └── Bavodu.gpg
```

Os nomes dos blobs são pseudônimos legíveis e aleatórios (`Azaus.gpg`,
`Kelitum.gpg`). Não derivam do caminho lógico e não revelam nada sobre o
conteúdo; servem só para o humano reconhecer que são blobs. Stores criados
antes desta mudança continuam funcionando: blobs antigos (hex) e novos
podem coexistir na mesma identidade.

O `.map.gpg` mantém a relação entre o caminho lógico e o blob físico.

Isso permite alterar o nome lógico sem modificar o ciphertext do segredo.

## Dependências

* Bash
* GPG
* `flock`
* `mktemp`
* `shred`
* `git` (opcional)
* `wl-copy` / `wl-paste` para clipboard
* `oathtool` ou `otptool` para OTP
* `qrencode` para QR Code

O clipboard atualmente utiliza **Wayland**.

## Configuração

O store padrão é `$HOME/.npass` (por usuário). O programa é global
(`/usr/bin/npass`, acessível a todos os usuários); os dados não.

Pode ser alterado com:

```bash
export NPASS_STORE="$HOME/.npass"
```

Se existir um store no local antigo (`$XDG_DATA_HOME/npass`), o npass avisa
como movê-lo; nunca move nada sozinho.

Outras variáveis:

```text
NPASS_GPG
NPASS_LANG
NPASS_GENERATED_LENGTH
NPASS_DICEWARE_SEP
NPASS_WORDLIST
NPASS_WORDLIST_SRC
NPASS_CLIP_TIME
NPASS_ENABLE_EXTENSIONS
NPASS_EXTENSIONS_DIR
```

## Uso

Criar uma identidade:

```bash
npass init pessoal CHAVE_GPG
```

Inserir uma senha:

```bash
npass insert pessoal email/gmail
```

Mostrar:

```bash
npass show pessoal email/gmail
```

Copiar para o clipboard (só a senha, por padrão):

```bash
npass clip pessoal email/gmail          # senha (1ª linha)
npass clip pass pessoal email/gmail     # idem, explícito
npass clip email pessoal email/gmail    # valor da linha "email: ..."
npass clip all pessoal email/gmail      # entrada inteira
```

Com 2 argumentos é `ID CAMINHO`; com 3, `CAMPO ID CAMINHO`. O campo é
comparado sem diferenciar maiúsculas e aceita prefixo único (`email` acha
`email-alias` se for a única chave começando com `email`).

Listar as identidades (conta os blobs em disco, sem decifrar nada):

```bash
npass identities
# HG - 100 senhas
# Vupon - 25 senhas
```

Gerar uma senha:

```bash
npass generate pessoal email/gmail
```

Listar entradas:

```bash
npass ls pessoal
```

Editar:

```bash
npass edit pessoal email/gmail
```

Remover:

```bash
npass rm pessoal email/gmail
```

Renomear:

```bash
npass mv pessoal email/gmail email/google
```

Rotacionar senhas:

```bash
npass update pessoal email/
```

## PIN

`npass pin` gera um PIN numérico. O **modo é obrigatório**: há sistemas que usam o PIN como a própria senha e outros que o usam como fator extra ao lado de uma senha, e adivinhar o modo sobrescreveria uma senha de verdade ou deixaria o PIN onde se espera uma senha.

```bash
npass pin --password pessoal cartao/debito     # o PIN É a senha da entrada (6 dígitos)
npass pin --field pessoal banco/app 8          # o PIN vira o campo "pin:" (8 dígitos); a senha não é tocada
npass clip pin pessoal banco/app               # copia o campo pin
```

- **`--password`**: o PIN substitui a senha da entrada (ou a constitui, se a entrada não existe). Em entrada existente pergunta antes de sobrescrever; `-f` não pergunta; `--in-place` troca só a 1ª linha e preserva login, OTP e notas.
- **`--field`**: acrescenta (ou atualiza) a linha `pin: NNNN` no fim do bloco de campos, antes das notas; a senha e tudo o mais ficam intactos. **A entrada precisa existir**: um erro de digitação no caminho não pode criar uma entrada órfã que parece anexada à certa. Crie-a antes com `insert` ou `generate`. Se já houver `pin:`, pergunta antes de substituir (`-f` não pergunta); só a primeira ocorrência é trocada, que é a que `npass clip pin` lê.
- Dígitos: 4 a 32, padrão 6 (`NPASS_PIN_LENGTH` muda o padrão). O PIN é copiado para o clipboard por padrão; as mensagens saem no stderr. Zeros à esquerda são preservados (o PIN é texto, nunca número).
- **Um PIN tem pouca entropia** (6 dígitos ≈ 19,9 bits). Só é seguro onde o sistema limita as tentativas (cartão, celular, TPM). Não o use como senha de conta que aceite tentativas ilimitadas ou que possa ser atacada offline.
- Se a entrada existe mas não pode ser decifrada, o comando para sem alterar nada. A única exceção é `--password -f`, que a sobrescreve de propósito.

## OTP

Gerar código:

```bash
npass otp pessoal email/gmail
```

Copiar código:

```bash
npass otp clip pessoal email/gmail
```

Mostrar URI:

```bash
npass otp uri pessoal email/gmail
```

O npass suporta **TOTP e HOTP** através de URIs `otpauth://`.

## Diceware
Atenção: No futuro a lista wordlist será reescrita, os indices passarão a não viver junto das palavras. seu indice de palavras será encriptado e único sendo fornecido na hora, você precisará manter seu indice em backup no futuro leve isso em consideração na sua estratégia de segurança.

Frases de palavras com as listas da EFF, todas num único arquivo (`encrypts_alternatives/wordlist.txt`):

```bash
npass diceware pessoal banco/itau              # 6 palavras da EFF Large (~77,5 bits)
npass diceware -s '::' pessoal banco/itau 8    # 8 palavras, separador "::"
npass memorable pessoal wifi/casa              # palavras curtas, para decorar; sem alturas
npass memorable -l short1 pessoal wifi/casa    # só a Short #1 (palavras de até 5 letras)
```

**`diceware`** grava a frase no cofre e mostra no terminal só a *altura* de cada palavra (o número de dados dela na lista publicada), para você anotar em papel:

```text
ALTURAS - anote em papel, nesta ordem:

    56111 62521 52251 16521 51416 51231

Separador: "-" (anote também)
```

Se você perder o gerenciador, a senha se refaz: ache cada altura na lista (a sua `~/.npass/wordlist.txt`, seção `[large]`, ou a lista pública da EFF) e junte as palavras com o separador. A frase em si não é mostrada (use `npass show` ou `-c`), e as alturas **não são gravadas em lugar nenhum**: saem no **stderr**, para não irem parar sem querer num pipe, num arquivo ou num `$(...)`.

> **O papel com as alturas é a sua senha.** A lista é pública, então quem tiver o papel reconstrói a senha sem precisar do cofre nem da sua chave. Guarde-o longe do computador e do cofre; nunca em arquivo, foto, nuvem ou app de notas; e limpe a tela e o scrollback do terminal depois de anotar.

**`memorable`** usa as listas Short (#1 e #2.0 juntas: 2.448 palavras distintas; `-l short1` ou `-l short2` escolhe uma só) e **não tem índice**: a frase aparece no terminal (ou vai para o clipboard com `-c`) para ser decorada.

Opções dos dois: `-s/--sep SEP` (0 a 3 caracteres, padrão `-`), `-c`, `-f`, `--in-place` (troca só a 1ª linha e preserva OTP e notas) e o número de palavras (4 a 20, padrão 6). O separador pode ser predefinido com `export NPASS_DICEWARE_SEP='.'` (vazio = sem separador); `--sep` vence. A entropia sai calculada sobre a lista realmente usada.

A lista fica em `~/.npass/wordlist.txt` (ou `NPASS_WORDLIST`). Na primeira vez o npass a copia da que acompanha a instalação (`PREFIX/share/npass/encrypts_alternatives/`, ou `encrypts_alternatives/` num clone do repositório; `NPASS_WORDLIST_SRC` força a origem). É só dado, nunca executado, e o npass recusa uma lista com menos de 1296 palavras utilizáveis (sinal de arquivo truncado ou adulterado). Formato: seções `[large]`, `[short1]`, `[short2]`, linhas `ALTURA<TAB>palavra`. Listas da EFF, licença CC BY 3.0 US.

## Git

Todo store nasce como repositório Git: o primeiro `npass init` cria o
repositório em `$NPASS_STORE`, e cada comando que altera algo commita sozinho
(escopo por identidade). Se não houver `user.name`/`user.email` configurados,
o npass usa uma identidade local `npass <npass@localhost>` só nesse repo.
Stores antigos, sem repositório, ganham um no primeiro comando que os altere.

Atenção: o histórico do Git guarda os blobs antigos. Remover ou rotacionar
uma senha não a apaga do histórico.

Os caminhos lógicos das senhas não são utilizados nas mensagens desses commits.

## Migração e importação

Toda a importação vive na extensão opcional `npass-import` (veja "Extensões"), inclusive a migração de stores do `pass`:

```bash
npass import pass pessoal ~/.password-store                  # store pass tradicional
npass import pass-secrets pessoal /caminho/da/identidade     # layout pass-secrets-redesign
```

- Se a identidade `pessoal` ainda não existir e a origem tiver `.gpg-id`, ela é criada com os mesmos destinatários, e já **assinada** se a origem tiver `.gpg-id.sig`. Uma identidade que já existia nunca é assinada como efeito colateral (isso continua sendo `npass sign`).
- As fontes não são removidas por padrão (`--delete-source` apaga cada `.gpg` depois de importar com sucesso). O que já existe é pulado; `-f` sobrescreve. `-p PREFIXO` e `--dry-run` também valem aqui.
- No `pass-secrets` o codinome continua sendo o caminho lógico (para não ir parar no histórico do shell nem em `/proc/*/cmdline`); o nome real e o alias de e-mail viram notas dentro do segredo cifrado (`# nome-real: ...`, `# email-alias: ...`).

> `npass migrate` e `npass migrate-secrets` não existem mais no core: viraram `npass import pass` e `npass import pass-secrets`. Rodar o comando antigo mostra esse aviso.

Para importar de **outros gerenciadores** (Bitwarden, KeePassXC, Firefox, Chrome, LastPass, 1Password, Aegis, andOTP, CSV genérico), é a mesma extensão: seção abaixo.

## Extensões

As extensões são desativadas por padrão.

Para habilitá-las:

```bash
export NPASS_ENABLE_EXTENSIONS=1
```

Extensões precisam ser arquivos regulares, possuir permissões restritivas e uma assinatura GPG válida, feita por uma chave **sua** (`npass extension sign ARQUIVO`; confira com `npass extension list`). A extensão recebe `NPASS_STORE`, `NPASS_GPG`, `NPASS_LANG` e `NPASS_BIN` (o `npass` exato que a executou).

### Instalando as extensões que acompanham o repositório

O `install.sh` **não instala nenhuma extensão por padrão**. Rodando num terminal, depois de instalar o npass ele oferece cada extensão de `extensions/`, uma por uma e com uma descrição curta; as que você aceitar já vão direto para o destino final (`~/.local/share/npass/extensions`) e são assinadas com a sua chave. Instalar É o ato de confiar: leia antes.

```bash
sudo ./install.sh                  # instala o npass e, num terminal, oferece as extensões
./install.sh --extensions-only     # só as extensões (ex.: você usa o pacote do AUR)
./install.sh --no-extensions       # nunca oferece
./install.sh --sign-key=KEYID      # chave usada para assinar (padrão: a padrão do gpg)
```

- Sob `sudo`, o destino e a assinatura são do usuário que chamou o `sudo` (`SUDO_USER`), não do root.
- Nada é perguntado quando a entrada não é um terminal nem com `DESTDIR` (empacotamento). O PKGBUILD usa `--no-extensions`.
- `--uninstall` remove só o npass; as suas extensões ficam onde estão.
- Se a assinatura falhar, o arquivo fica no lugar e o instalador mostra o comando exato (`npass extension sign ...`).
- Para uma extensão sua aparecer no instalador, coloque nas 20 primeiras linhas `# npass-extension-desc: descrição curta` e, opcionalmente, `# npass-extension-needs: comando1 comando2` (avisa se faltar). Um arquivo `npass-foo.bash` é instalado como `npass-foo` e roda como `npass foo`.

Extensões que acompanham:

- **`npass-import`**: importa de outros gerenciadores e de stores `pass`/`pass-secrets` (abaixo). Precisa de `python3`.
- **`npass-clip-x11`**: copia a senha ou um campo para o clipboard do X11, para quem ainda usa sessão gráfica X11 (o `clip` do core é Wayland). `npass clip-x11 [CAMPO] ID DIR/PASS`. Precisa de `xclip`.
- **`npass-wclip`**: copia a senha ou um campo para o clipboard do windows, Por favor ler [Documentação](~/windows_Requisitos.md)

### npass-import: importar de outros gerenciadores

Só biblioteca padrão do Python 3, sem rede.

```bash
npass import --list
```

Uso: `npass import [opções] FORMATO ID ARQUIVO...`

```bash
npass import bitwarden pessoal bitwarden_export.json
npass import keepassxc pessoal export.csv -p Importado      # tudo sob "Importado/"
npass import firefox pessoal logins.csv --dry-run            # mostra o que faria, sem gravar
npass import csv pessoal dados.csv --cols 'url,login,,password' --skip-header
npass import aegis pessoal aegis-plain.json                  # vira URIs otpauth:// (npass otp)
npass import bitwarden pessoal export.csv.gpg                # .gpg é decifrado em memória
npass import pass pessoal ~/.password-store                  # store pass tradicional
npass import pass-secrets pessoal /caminho/da/identidade     # layout pass-secrets-redesign
```

Formatos: `csv` (genérico), `bitwarden` (csv/json), `keepassxc`/`keepass`, `firefox`, `chrome`, `lastpass`, `1password`, `aegis`, `andotp`, `pass`, `pass-secrets`.

- Por padrão **pula** o que já existe (reimportar é seguro); `-f` sobrescreve. Títulos repetidos viram `titulo/login`.
- Opções: `-p PREFIXO`, `-f`, `-d/--dry-run`, `-v`, `--delete-source`, `--encoding`, `--del`, `--cols`, `--skip-header`.
- O conteúdo segue o formato do `pass` (`senha` na 1ª linha, depois `login:`, `url:`, campos extras, URI OTP e notas), então `npass clip login ...` e `npass otp ...` funcionam.
- Os segredos trafegam por pipe no stdin do `npass insert --batch`: nunca em argv, variável de ambiente ou arquivo temporário. O lote inteiro gera **um** commit Git.
- Exports **criptografados** (Bitwarden, Aegis, andOTP) são recusados: exporte a versão sem criptografia, importe e apague. **O arquivo exportado é uma cópia em claro de todas as suas senhas.** Prefira cifrá-lo com `gpg` antes (a extensão lê `.gpg`) ou usar `/dev/shm`. `--delete-source` usa `shred`, que **não é confiável em btrfs** (copy-on-write) nem em SSD.
- Os parsers de formatos exportados foram escritos a partir do formato documentado de cada gerenciador e testados com fixtures sintéticos. Antes de confiar em um formato, importe um export real com `--dry-run` e confira.

### npass-passkey: passkeys (WebAuthn/FIDO2) no desktop

Registra e usa passkeys reais em sites, com o **npass como único armazenamento**:

```text
navegador -> WebAuthn -> npass-passkeyd (Rust: CTAP2 + UHID) -> npass-passkey -> npass
```

```bash
npass passkey list ID [RP] [LOGIN]      # descoberta, só pelo índice Fido/.map
npass passkey store ID RP LOGIN < CRED  # credencial em base64 (CBOR) no stdin
npass passkey load ID BLOB
npass passkey rm ID BLOB
npass passkey verify ID [--deep]        # hash, assinaturas, órfãos, duplicatas
npass passkey rebuild-index ID
npass passkey serve ID                  # valida o helper e sobe o autenticador virtual
```

- Cada passkey é um blob opaco `ID/Fido/<hex>.gpg`: cabeçalho público (`rp_id`, `login`,
  hash do payload, assinatura GPG) + payload cifrado. `Fido/.map` (0600, com lock) só ajuda a
  achar candidatos; **nunca é autoridade**. Vários blobs podem ter o mesmo RP/login.
- O `install.sh` só compila o daemon (`cargo build --release --locked` em `passkey/`) se você
  escolher `npass-passkey`; as demais extensões não precisam de Rust. O helper vai para
  `~/.local/share/npass/helpers/` e é assinado junto com um selo que o amarra a esta versão da extensão.
- Requer `/dev/uhid` acessível ao seu usuário (`modprobe uhid` + regra udev). A presença do
  usuário é pedida por `zenity`/`kdialog`, pelo terminal ou por `--confirm-cmd`; sem nenhum, nega.
  Não existe modo "aprovar tudo".
- `rp_id` e `login` ficam **em claro** nos blobs e no `.map` (e no git do store), por desenho.
  `NPASS_PASSKEY_GIT=0` desliga o commit automático de `Fido/`.

#### PIN e política de exigência (por identidade)

```bash
npass passkey pin set ID                       # define o PIN: 4 a 64 caracteres [A-Za-z0-9]
npass passkey pin change ID                    # troca: pede o PIN atual
npass passkey pin change ID --gpg              # troca: prova com a senha da chave GPG (também desbloqueia)
npass passkey pin policy ID                    # mostra a política
npass passkey pin policy ID nunca|opcional|requerido   # muda (exige PIN atual ou --gpg)
npass passkey pin status ID                    # política, se há PIN, tentativas restantes
```

| política | quando o PIN é pedido |
|---|---|
| `nunca` | nunca (só a confirmação de presença), mesmo com PIN definido |
| `opcional` (padrão) | se houver PIN **e** o site pedir verificação do usuário (UV) |
| `requerido` | em toda operação; sem PIN definido, tudo é negado |

- **5 erros seguidos bloqueiam** o PIN (nem o PIN certo vale depois). O contador sobe *antes* de
  comparar e zera no acerto. Desbloqueio: `pin change ID --gpg`.
- Tudo fica em `ID/Fido/`: `.pin.gpg` (hash do PIN + política, cifrado **e assinado** pelas chaves da
  identidade, 0600) e `.pin-tries` (contador, 0600, nunca vai ao git). Cada identidade só enxerga o seu.
- O daemon pede o PIN por `zenity`, `kdialog`, terminal ou `--pin-cmd CMD` (o comando imprime o PIN).
- Criar uma passkey descobrível sempre conta como verificação do usuário (CTAP2), então, com PIN
  definido, o **registro** pede o PIN mesmo em `opcional`.

## Desenvolvimento

O executável principal é **gerado** a partir dos arquivos em `lib/`.

Não edite diretamente o arquivo gerado.

Após alterar os arquivos-fonte:

```bash
./build.sh
```

A estrutura do projeto separa as responsabilidades entre módulos de identidade, armazenamento, clipboard e OTP.

## Segurança

O projeto utiliza GPG para os dados, um mapa criptografado para ocultar os caminhos lógicos e nomes físicos aleatórios para os blobs.

Arquivos temporários são criados com permissões restritivas e removidos ao final das operações.

A implementação é considerada pronta para uso. Como em qualquer gerenciador de senhas, recomenda-se manter backups seguros do store e revisar as práticas de segurança do ambiente onde o GPG e o npass são utilizados.
