# npass

Gerenciador de senhas para Linux baseado em **Bash + GPG**, com armazenamento por identidades, mapa lógico criptografado e blobs físicos com nomes opacos.

## Status

**Versão:** `1.4`
**Estado:** versão beta

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

## Migração

Migrar um store tradicional do `pass`:

```bash
npass migrate pessoal ~/.password-store
```

Migrar um store `pass-secrets-redesign`:

```bash
npass migrate-secrets pessoal /caminho/da/identidade
```

Por padrão, as fontes não são removidas.

Para importar de **outros gerenciadores** (Bitwarden, KeePassXC, Firefox, Chrome, LastPass, 1Password, Aegis, andOTP, CSV genérico), use a extensão `npass-import` (seção abaixo).

## Extensões

As extensões são desativadas por padrão.

Para habilitá-las:

```bash
export NPASS_ENABLE_EXTENSIONS=1
```

Extensões precisam ser arquivos regulares, possuir permissões restritivas e uma assinatura GPG válida.

`npass extension install ARQUIVO [KEYID]` copia o arquivo (que deve se chamar `npass-NOME`) para o diretório de extensões e o assina com a sua chave num passo só. Instalar É o ato de confiar: leia o arquivo antes. A extensão recebe `NPASS_STORE`, `NPASS_GPG`, `NPASS_LANG` e `NPASS_BIN` (o `npass` exato que a executou).

### npass-import: importar de outros gerenciadores

Vem junto com a instalação em `PREFIX/share/npass/extensions/npass-import` (precisa de `python3`, só biblioteca padrão, sem rede). Ela **não** fica ativa sozinha:

```bash
npass extension install /usr/share/npass/extensions/npass-import
export NPASS_ENABLE_EXTENSIONS=1
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
npass import pass pessoal ~/.password-store                  # = npass migrate
npass import pass-secrets pessoal /caminho/da/identidade     # = npass migrate-secrets
```

Formatos: `csv` (genérico), `bitwarden` (csv/json), `keepassxc`/`keepass`, `firefox`, `chrome`, `lastpass`, `1password`, `aegis`, `andotp`, `pass`, `pass-secrets`.

- Por padrão **pula** o que já existe (reimportar é seguro); `-f` sobrescreve. Títulos repetidos viram `titulo/login`.
- Opções: `-p PREFIXO`, `-f`, `-d/--dry-run`, `-v`, `--delete-source`, `--encoding`, `--del`, `--cols`, `--skip-header`.
- O conteúdo segue o formato do `pass` (`senha` na 1ª linha, depois `login:`, `url:`, campos extras, URI OTP e notas), então `npass clip login ...` e `npass otp ...` funcionam.
- Os segredos trafegam por pipe no stdin do `npass insert --batch`: nunca em argv, variável de ambiente ou arquivo temporário. O lote inteiro gera **um** commit Git.
- Exports **criptografados** (Bitwarden, Aegis, andOTP) são recusados: exporte a versão sem criptografia, importe e apague. **O arquivo exportado é uma cópia em claro de todas as suas senhas.** Prefira cifrá-lo com `gpg` antes (a extensão lê `.gpg`) ou usar `/dev/shm`. `--delete-source` usa `shred`, que **não é confiável em btrfs** (copy-on-write) nem em SSD.
- Os parsers foram escritos a partir do formato documentado de cada gerenciador e testados com fixtures sintéticos. Antes de confiar em um formato, importe um export real com `--dry-run` e confira.

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
