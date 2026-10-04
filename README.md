# npass

Gerenciador de senhas para Linux baseado em **Bash + GPG**, com armazenamento por identidades, mapa lógico criptografado e blobs físicos com nomes opacos.

## Status

**Versão:** `2.0`
**Estado:** Pronto para uso

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
