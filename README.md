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
* `glow` para `npass show` renderizado no terminal (sem ele, o `show` avisa e imprime o texto cru)
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

## Ajuda

`npass help` mostra só o **essencial** (os 10 comandos do dia a dia) e a lista de categorias. O resto fica em categorias, e cada categoria tem seções:

```bash
npass help                      # essencial + categorias
npass help gerar                # a categoria inteira, com as seções (senha aleatória, frases, PIN)
npass help gerar frases         # só uma seção
npass help todos                # tudo, categoria por categoria (alias: all, tudo)
```

Categorias: `entradas` (ver, escrever, mover e remover, em massa), `gerar` (senha aleatória, frases, PIN), `otp` (código, cadastro), `backup` (gravar, navegar), `buscar` (caminhos, conteúdo), `identidades` (criar, listar, assinar), `git` e `extensoes` (gerenciar, disponíveis). Os nomes de categoria e de seção são exatos, em minúsculas e sem acento (uma categoria ou seção desconhecida mostra as válidas). Todo comando despachado pelo `npass`, e toda extensão do repositório, aparece em alguma categoria: `tests/help.bats` falha se um comando ou extensão ficar sem ajuda.

## Uso

Criar uma identidade:

```bash
npass init pessoal CHAVE_GPG
```

Inserir uma senha:

```bash
npass insert pessoal email/gmail
```

Mostrar (em terminal sai **renderizado pelo `glow`**; em pipe, script ou extensão sai o documento md1 cru):

```bash
npass show pessoal email/gmail            # terminal: renderizado; pipe: cru
npass show --raw pessoal email/gmail      # sempre cru
npass show --render pessoal email/gmail | less -R   # renderizado mesmo em pipe
```

O `glow` é **dependência do `show` em terminal**: sem ele o npass avisa e imprime o texto cru (nunca deixa de mostrar). O que o `glow` recebe não é o documento md1, e sim um documento só de **exibição**, porque markdown renderizado deforma texto (`a*b*c_d_` viraria itálico, `<`, `&` e `\` somem, uma senha começando com `#` viraria título) e você copiaria da tela uma senha diferente da guardada:

- a **senha**, o **OTP** e os **valores dos campos** vão em bloco ou span de código, sempre com cerca mais longa que qualquer sequência de crases do próprio texto; os nomes de campo são escapados;
- valores `http(s)://` viram link clicável (autolink, URL mostrada uma vez); com um valor de aparência suspeita (`<`, `>`, `(`, `)`, crase, barra invertida, espaço) vira só código;
- as **notas** são markdown de verdade: negrito, listas e links funcionam;
- o texto vai ao `glow` por **stdin**, nunca por argumento, e nada é gravado em disco.

Variáveis: `NPASS_SHOW_RENDER=auto|always|never` (padrão `auto`: renderiza só em terminal; a flag `--raw`/`--render` vence a variável), `NPASS_GLOW` (caminho do binário), `NPASS_GLOW_STYLE` (`-s` do glow: `dark`, `light`, `notty`...) e `NPASS_GLOW_WIDTH` (`-w`). O npass não passa `-p`; se o seu `glow.yml` tiver `pager: true`, o pager abre por escolha sua. **Para copiar a senha use `npass clip`**: o `glow` desenha margem e preenchimento ao redor do texto, e selecionar da tela leva isso junto. Entrada no formato antigo ou com estrutura inválida sai crua, sem renderizar.

Copiar para o clipboard (só a senha, por padrão):

```bash
npass clip pessoal email/gmail          # senha (seção "## Senha")
npass clip pass pessoal email/gmail     # idem, explícito
npass clip email pessoal email/gmail    # valor da linha "- email: ..."
npass clip all pessoal email/gmail      # o documento md1 inteiro
npass get email pessoal email/gmail     # imprime no stdout em vez de copiar (mesmos argumentos)
```

`get` recebe os mesmos argumentos do `clip` e imprime o valor em vez de copiá-lo: é o que as extensões de clipboard (`wclip`, `clip-x11`) chamam, para o formato ser lido em um lugar só.

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

Listar entradas (árvore dos caminhos lógicos; só lê o mapa, não decifra nada):

```bash
npass tree pessoal               # árvore inteira
npass tree pessoal banco         # só o que está sob banco/ (prefixo por componente: "ban" não casa "banco")
npass tree --flat pessoal        # um caminho por linha, sem enfeite: é o que os scripts e as extensões usam
```

```text
pessoal
├── banco/
│   ├── itau/
│   │   ├── cartao
│   │   └── conta
│   └── nubank
└── email/
    ├── gmail  [backup]
    │   ├── Backup-gmail.dados.md
    │   └── Backup-gmail.md
    └── outlook
```

Pasta (só aparece como prefixo) termina em `/`; entrada não. Uma entrada pode ser as duas coisas (`gmail` e `gmail/Backup-gmail.md`). `[backup]` marca a entrada que tem o par de anexos de `npass backup`, pelos nomes, sem decifrar; os anexos continuam listados. Sem UTF-8 no locale o desenho cai para ASCII, e a cor (pastas em negrito/azul) só aparece em terminal e sem `NO_COLOR`.

> `npass ls` (e `list`) deixou de existir: rodar o comando antigo mostra o aviso para o `tree`. Quem usava a saída em script troca por `tree --flat`. Diferenças do `--flat` para o `ls`: sem a linha de cabeçalho com o ID e sem indentação de dois espaços; identidade inexistente agora é erro (antes só avisava e saía com 0); `DIR` agora é prefixo de verdade, por componente.

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

## Formato das entradas (md1)

O conteúdo cifrado de **toda** entrada é um documento markdown com este formato (`npass show` o imprime como está):

```markdown
<!-- npass:md1 -->
## Senha
valor-cru-sem-trim

## Campos
- login: fulano
- url: https://exemplo.com

## OTP
otpauth://totp/...

## Notas
texto livre; sempre a última seção
```

- A 1ª linha é exatamente o marcador. Sem ele a entrada **não está em md1** (veja "Migração e importação").
- `## Senha` é obrigatória e vem primeiro. A senha é a linha logo abaixo do cabeçalho, lida **por posição e sem tirar espaços**: uma senha pode ser `## Campos`, `- x: y` ou começar com `#` sem confundir o parser.
- `## Campos`, `## OTP` e `## Notas` são opcionais, nessa ordem e no máximo uma vez cada. Uma linha de campo é `- chave: valor`; a chave não diferencia maiúsculas. Entrada só de OTP tem `## Senha` vazia.
- `## Notas` vai até o fim do documento: tudo depois dela é nota, mesmo que pareça cabeçalho ou campo (e por isso nunca vira campo).
- Linha não reconhecida dentro de Campos/OTP é mantida como está ao reescrever. Estrutura inválida (seção fora de ordem ou repetida, texto solto) é recusada, nunca "consertada" em silêncio.
- **Só md1 entra:** `insert`, `generate`, `pin`, `diceware`, `otp insert` e os imports gravam md1; `insert --batch` e `edit` recusam qualquer outra coisa; `update -m` espera o documento completo. O único parser do formato é `lib/14-entry.bash`.
- Uma entrada ainda no formato antigo (texto puro, senha na 1ª linha) **não é lida** por `get`, `clip`, `otp`, `pin`, `generate --in-place`, `update` nem `edit`: o comando para e manda rodar `npass import npass-legacy ID`. `show`, `ls`, `grep`, `mv` e `rm` continuam funcionando com ela.

## PIN

`npass pin` gera um PIN numérico. O **modo é obrigatório**: há sistemas que usam o PIN como a própria senha e outros que o usam como fator extra ao lado de uma senha, e adivinhar o modo sobrescreveria uma senha de verdade ou deixaria o PIN onde se espera uma senha.

```bash
npass pin --password pessoal cartao/debito     # o PIN É a senha da entrada (6 dígitos)
npass pin --field pessoal banco/app 8          # o PIN vira o campo "- pin:" (8 dígitos); a senha não é tocada
npass clip pin pessoal banco/app               # copia o campo pin
```

- **`--password`**: o PIN substitui a senha da entrada (ou a constitui, se a entrada não existe). Em entrada existente pergunta antes de sobrescrever; `-f` não pergunta; `--in-place` troca só a senha e preserva campos, OTP e notas.
- **`--field`**: acrescenta (ou atualiza) a linha `- pin: NNNN` no fim da seção `## Campos` (que é criada se não existir), antes do OTP e das notas; a senha e tudo o mais ficam intactos. **A entrada precisa existir**: um erro de digitação no caminho não pode criar uma entrada órfã que parece anexada à certa. Crie-a antes com `insert` ou `generate`. Se já houver `pin:`, pergunta antes de substituir (`-f` não pergunta); só a primeira ocorrência é trocada, que é a que `npass clip pin` lê.
- Dígitos: 4 a 32, padrão 6 (`NPASS_PIN_LENGTH` muda o padrão). O PIN é copiado para o clipboard por padrão; as mensagens saem no stderr. Zeros à esquerda são preservados (o PIN é texto, nunca número).
- **Um PIN tem pouca entropia** (6 dígitos ≈ 19,9 bits). Só é seguro onde o sistema limita as tentativas (cartão, celular, TPM). Não o use como senha de conta que aceite tentativas ilimitadas ou que possa ser atacada offline.
- Se a entrada existe mas não pode ser decifrada, o comando para sem alterar nada. A única exceção é `--password -f`, que a sobrescreve de propósito.

## Senhas de backup

`npass backup` guarda **N senhas de backup** (códigos de recuperação) num arquivo cifrado, anexo a uma entrada que já existe. Você digita as senhas de forma interativa (ocultas, cada uma com confirmação); nada vai ao disco em claro.

```bash
npass backup -n 3 pessoal email/gmail
```

Gera dois blobs na mesma identidade, cifrados para os mesmos destinatários do `.gpg-id`:

| Caminho lógico | Conteúdo |
|---|---|
| `email/gmail/Backup-gmail.md` | ponteiro **sem segredo**: nome do arquivo de dados, quantidade e data |
| `email/gmail/Backup-gmail.dados.md` | as senhas, uma por seção (`## Backup 1`, `## Backup 2`, ...) |

```bash
npass show pessoal email/gmail/Backup-gmail.dados.md
```

- `-n N`: de 1 a 50. Senha vazia, repetida ou com confirmação diferente interrompe o comando antes de gravar qualquer coisa.
- **A entrada precisa existir**, como em `pin --field`: um erro de digitação no caminho não cria um anexo órfão.
- Já existe backup: pergunta antes de substituir (`-f` não pergunta). Só substitui anexos de verdade.
- **Navegação contextual (só na exibição renderizada):** `npass show` de uma entrada com backup ganha, logo abaixo do título, `Backup: [Asyx](npass://pessoal/QWAP/Asyx/Backup-Asyx.dados.md)`; o arquivo de dados e o ponteiro ganham `Entrada: [Asyx](npass://pessoal/QWAP/Asyx)` de volta, e o campo `arquivo` do ponteiro liga ao arquivo de dados. Os links são **calculados na hora, nunca gravados**: `show --raw`, `get`, `clip` e as extensões não os veem, e um `mv`, `rm` ou renomeação nunca deixa um link velho. Só conta um par completo de anexos (`Backup-X.md` **e** `Backup-X.dados.md`, filhos diretos da entrada), decidido pelos nomes, sem decifrar; o texto do link é o nome do anexo (depois de renomear a entrada continua `Backup-gmail`). Clicar chama `npass open` (veja "Links `npass://`"), que pergunta antes de mostrar as senhas de backup.
- Os anexos acompanham a entrada: `rm` remove os dois (com aviso antes de perguntar), `mv` os leva para o novo caminho (também entre identidades) e `update` e `audit` os ignoram, para não rotacionar nem auditar um arquivo de backup como se fosse senha de login.
- Um arquivo só é tratado como anexo quando o **nome** (`Backup-*.md`, filho direto da entrada) **e** o marcador na primeira linha (`<!-- npass:backup-index v1 -->` ou `...backup-data v1 -->`) batem. Uma entrada sua chamada `Backup-x.md` nunca é arrastada por `rm`/`mv`.
- Como as senhas ficam em `show`/`tree` como qualquer outra entrada, quem tem a chave do `.gpg-id` lê tudo: o anexo separa o backup da entrada principal (`show` e `clip all` da entrada não o despejam), não cria um segundo nível de proteção.

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

Opções dos dois: `-s/--sep SEP` (0 a 3 caracteres, padrão `-`), `-c`, `-f`, `--in-place` (troca só a senha e preserva campos, OTP e notas) e o número de palavras (4 a 20, padrão 6). O separador pode ser predefinido com `export NPASS_DICEWARE_SEP='.'` (vazio = sem separador); `--sep` vence. A entropia sai calculada sobre a lista realmente usada.

A lista fica em `~/.npass/wordlist.txt` (ou `NPASS_WORDLIST`). Na primeira vez o npass a copia da que acompanha a instalação (`PREFIX/share/npass/encrypts_alternatives/`, ou `encrypts_alternatives/` num clone do repositório; `NPASS_WORDLIST_SRC` força a origem). É só dado, nunca executado, e o npass recusa uma lista com menos de 1296 palavras utilizáveis (sinal de arquivo truncado ou adulterado). Formato: seções `[large]`, `[short1]`, `[short2]`, linhas `ALTURA<TAB>palavra`. Listas da EFF, licença CC BY 3.0 US.

## Links `npass://` e `npass open`

O `show` renderizado desenha links `npass://ID/DIR/PASS` (hoje, entre uma entrada e os seus backups). O `glow` os emite como **hiperlink OSC 8**; em um terminal que suporte OSC 8 (por exemplo foot e kitty; confira o seu) o clique entrega a URL ao desktop, e a URL também aparece escrita ao lado do texto, então em terminal sem OSC 8 você a copia e roda `npass open`.

```bash
npass open npass://pessoal/email/gmail            # mostra a entrada (pede confirmação)
npass open --here npass://pessoal/email/gmail     # sempre neste terminal
```

- **O handler:** `install.sh` instala `share/applications/npass-open.desktop` (`MimeType=x-scheme-handler/npass`, com o caminho **absoluto** do binário no `Exec`) e roda `update-desktop-database`. Num pacote (PKGBUILD) o hook do pacman faz o registro. Com `--prefix=$HOME/.local` o arquivo vai para `~/.local/share/applications`. Verifique com `xdg-mime query default x-scheme-handler/npass`.
- **Sem terminal (chamado pelo desktop):** o `open` abre uma janela de terminal que roda `npass open --here --pause URL`. Quem escolhe o terminal é `NPASS_TERMINAL` (comando e argumentos, por exemplo `foot` ou `alacritty -e`), depois `$TERMINAL` (com `-e`), depois o primeiro que existir de foot, kitty, alacritty, wezterm, xterm. Sem nenhum, o erro explica como definir; o npass não chuta um.
- **`--pause`:** espera Enter (ou `NPASS_OPEN_TIMEOUT` segundos, padrão 60) e **limpa a tela e o scrollback**, para o segredo não ficar na janela.
- **Segurança:** qualquer coisa que consiga entregar uma URL `npass://` ao desktop (uma página web, uma nota importada, um link num e-mail) aciona este comando, então ele só **mostra** (nunca copia, grava nem altera nada), **pergunta `[y/N]` mostrando ID e caminho antes de decifrar qualquer coisa** (`NPASS_OPEN_CONFIRM=0` desliga, por sua conta e risco) e o parser é estrito: só o esquema `npass://`, ID simples (`A-Za-z0-9._-`), caminho sem `..`, sem controle e com `%`-escapes válidos (`%00` é recusado). Espaço, `#`, `?`, `%` e UTF-8 no nome da entrada viajam como `%XX`.

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
- No `pass-secrets` o codinome continua sendo o caminho lógico (para não ir parar no histórico do shell nem em `/proc/*/cmdline`); o nome real e o alias de e-mail viram os campos `- nome-real: ...` e `- email-alias: ...` dentro do segredo cifrado.
- O corpo de cada `.gpg` de um store `pass` é texto puro (formato antigo); o import o **converte para md1** na hora, pelas regras de "Converter do formato antigo" abaixo.

> `npass migrate` e `npass migrate-secrets` não existem mais no core: viraram `npass import pass`, `npass import pass-secrets` e `npass import npass-legacy`. Rodar o comando antigo mostra esse aviso.

### Converter do formato antigo (`npass-legacy`)

Entradas gravadas antes do md1 (texto puro, senha na 1ª linha) não são lidas pelo core. Convertê-las é um fluxo da mesma extensão, **no próprio store**:

```bash
npass import npass-legacy pessoal --dry-run   # lista o que seria convertido (~ caminho); não grava
npass import npass-legacy pessoal             # converte e grava
```

- Lê cada entrada com `npass show`, converte as que ainda estão no formato antigo e grava o lote com `insert --batch -f`: **um** commit Git, e o formato antigo continua no histórico (`git -C ~/.npass log`).
- **Idempotente:** o que já está em md1 e os anexos do `npass backup` não são tocados; rodar de novo diz que não há nada a converter.
- Regras da conversão: a 1ª linha é a senha (se for `otpauth://`, a entrada era só de OTP e a senha fica vazia); o **bloco de campos** é o prefixo de linhas `chave: valor` (ou `# chave: valor`) e `otpauth://`; uma linha em branco logo depois dele é só o separador; o resto vai para `## Notas` sem mudar uma vírgula. Linhas `otpauth://` e as etiquetas `# nome-real:` / `# email-alias:` que estiverem soltas nas notas **sobem** para OTP/Campos, para o OTP e a busca por campo continuarem funcionando.
- **O que muda de comportamento:** uma linha `chave: valor` que estava *depois* da primeira linha em branco (nas notas) era achada pelo `clip CAMPO` do formato antigo e agora fica nas notas, sem virar campo. O comando avisa, entrada por entrada (`ficaram nas notas`).
- **Cada conversão é verificada** antes de gravar: relê o md1 gerado e confere que a senha e as linhas `otpauth://` são idênticas e que toda linha não vazia do original aparece no resultado (como campo ou nota) o mesmo número de vezes. Se não passar, a entrada é mantida como estava e entra na contagem de falhas (saída ≠ 0).
- Identidade inexistente, ilegível ou entrada não decifrável: a entrada fica como está e o comando relata.

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

Formatos: `csv` (genérico), `bitwarden` (csv/json), `keepassxc`/`keepass`, `firefox`, `chrome`, `lastpass`, `1password`, `aegis`, `andotp`, `pass`, `pass-secrets` e `npass-legacy` (converte o próprio store, sem arquivo de origem).

- Por padrão **pula** o que já existe (reimportar é seguro); `-f` sobrescreve. Títulos repetidos viram `titulo/login`.
- Opções: `-p PREFIXO`, `-f`, `-d/--dry-run`, `-v`, `--delete-source`, `--encoding`, `--del`, `--cols`, `--skip-header`.
- Todo import grava **md1** (`## Senha`, `## Campos` com `login`, `email`, `url` e extras, `## OTP`, `## Notas`), então `npass clip login ...` e `npass otp ...` funcionam. Senha com quebra de linha é recusada (não cabe em md1).
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
