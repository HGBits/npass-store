# AGENTS.md - lib

## Escopo

Este é o código-fonte principal do `npass`. O executável em `bin/npass` é gerado a partir daqui.

## Mapa de módulos

| Arquivo | Responsabilidade |
|---|---|
| `00-main.bash` | inicialização, despacho e integração dos módulos |
| `01-common.bash` | utilitários e primitivas compartilhadas |
| `02-identity.bash` | identidades e configuração de destinatários GPG |
| `03-store.bash` | armazenamento, mapa lógico, blobs e operações de entrada |
| `04-clipboard.bash` | clipboard Wayland/core |
| `05-otp.bash` | TOTP/HOTP e URIs `otpauth://` |
| `06-update.bash` | atualização/rotação de entradas |
| `07-git.bash` | commits e integração Git |
| `08-pin.bash` | comando `pin`: PIN numérico como senha ou como campo `pin:` |
| `09-i18n.bash` | mensagens/traduções |
| `10-signing.bash` | assinatura e verificação |
| `11-extensions.bash` | descoberta, instalação e execução de extensões |
| `12-diceware.bash` | comandos `diceware` (com alturas) e `memorable` (sem índice); lista de palavras em `$NPASS_STORE/wordlist.txt`, criada pessoal (embaralhada) na primeira vez |
| `18-help.bash` | `npass help`: essencial no menu principal; categorias e seções saem de um bloco único (`npass_help_data`, marcadores `@cat`/`@sub`); novo comando = linha numa seção |
| `17-open.bash` | `npass open npass://ID/caminho` (handler do esquema), `npass_url_encode/_decode`, parser estrito, confirmação antes de decifrar, abre terminal (`NPASS_TERMINAL`) quando chamado sem tty |
| `16-view.bash` | comando `show` (`cmd_view`): renderiza com glow em terminal, cru em pipe; monta o documento de exibição (senha/OTP/valores em código, nomes escapados) e a navegação de backup calculada (`npass_nav_*`: `Backup:` na entrada, `Entrada:` no anexo); `cmd_show` (03) segue sendo o decifrador cru interno |
| `15-ls.bash` | comando `ls` (já se chamou `tree`): árvore dos caminhos lógicos a partir do mapa, `--flat` para máquina, marca `[backup]` por nome |
| `14-entry.bash` | formato md1: `npass_entry_load/_render/_new/_with_password/_require`, campos (`_field_get/_set/_has`) e OTP (`_otp_uri/_otp_set`); estado em globais `NPASS_E_*` (chame direto, nunca em `$(...)`) |
| `13-backup.bash` | comando `backup` e helpers de anexo (`npass_backup_attachments`, `npass_backup_is_attachment`, `npass_backup_drop`); `rm`/`mv`/`update` o chamam |

## Como localizar

- Problema de `init`, identidade ou `.gpg-id` -> `02-identity.bash`
- Problema de `insert/show/edit/rm/mv` -> `03-store.bash`
- Problema de `help`, categorias, seções, comando sem ajuda -> `18-help.bash`
- Problema de `open`, links `npass://`, handler do desktop, codificação de URL -> `17-open.bash`
- Problema de `show` renderizado, glow, documento de exibição -> `16-view.bash`
- Problema de `ls` (árvore, `--flat`, marca `[backup]`) -> `15-ls.bash`
- Problema envolvendo `.map.gpg` ou nomes de blobs -> `03-store.bash`
- Problema de clipboard padrão -> `04-clipboard.bash`
- Problema de OTP -> `05-otp.bash`
- Problema de update/rotação -> `06-update.bash`
- Commit automático/histórico -> `07-git.bash`
- PIN (`pin --password` / `pin --field`) -> `08-pin.bash`
- Texto traduzido -> `09-i18n.bash`
- Assinatura -> `10-signing.bash`
- Extensões -> `11-extensions.bash`
- Senhas de backup, anexos `Backup-*.md`, cascata em rm/mv -> `13-backup.bash`
- Diceware, frases memoráveis, alturas, separador, lista de palavras -> `12-diceware.bash` (a lista que acompanha o programa é `encrypts_alternatives/wordlist.txt`)

## Regra de dependência

Leia `01-common.bash` apenas quando a função analisada usar explicitamente seus helpers. Não trate `00-main.bash` como justificativa para ler todos os módulos.

Quando uma alteração cruzar módulos, registre mentalmente a direção:

```text
main -> módulo funcional -> helper/dependência
```

e não o contrário.

## Após alteração

```bash
./build.sh
```

Depois execute os testes diretamente relacionados à mudança.
