# AGENTS.md - npass

## Objetivo

Este arquivo é o índice operacional do projeto. Use-o para localizar rapidamente os arquivos relevantes antes de editar ou revisar código.

**Regra principal:** não varra o repositório inteiro. Primeiro identifique a tarefa abaixo, leia este arquivo e depois o `AGENTS.md` do diretório responsável. Só leia módulos adicionais quando houver uma dependência concreta.

## Mapa por tarefa

| Tarefa | Arquivo(s) inicial(is) | Depois |
|---|---|---|
| CLI, despacho de comandos, carregamento | `bin/npass`, `lib/00-main.bash` | módulo responsável |
| Funções comuns, validações e utilitários | `lib/01-common.bash` | módulo chamador |
| Identidades, chaves GPG, `.gpg-id` | `lib/02-identity.bash` | `lib/10-signing.bash` se assinatura |
| Store, mapa, blobs, CRUD | `lib/03-store.bash` | `lib/07-git.bash` se persistência/Git |
| **Formato do conteúdo das entradas (md1)**: parser, renderizador, `get` de campos | `lib/14-entry.bash` | `lib/04-clipboard.bash` (`get`/`clip`), `tests/entry-md1.bats` |
| Clipboard Wayland | `lib/04-clipboard.bash` | extensão correspondente se backend externo |
| Diceware/frases (`diceware`, `memorable`) e lista de palavras | `lib/12-diceware.bash` | `tests/diceware.bats`, `encrypts_alternatives/wordlist.txt` |
| OTP/TOTP/HOTP | `lib/05-otp.bash` | `tests/otp.bats` |
| Atualização/rotação | `lib/06-update.bash` | `lib/03-store.bash`, testes |
| Git automático | `lib/07-git.bash` | `tests/update.bats`, `tests/store-extras.bats` |
| Internacionalização | `lib/09-i18n.bash` | `tests/i18n.bats` |
| PIN numérico (`pin`, modos `--password`/`--field`) | `lib/08-pin.bash` | `tests/pin.bats` |
| Ajuda (`help`, categorias, seções) | `lib/18-help.bash` | `tests/help.bats` (falha se um comando de `lib/00-main.bash` ou uma extensão ficar sem ajuda) |
| Links `npass://` e `npass open` | `lib/17-open.bash`, `packaging/npass-open.desktop.in` | `install.sh` (instala o .desktop), `tests/open.bats`, `tests/install.bats` |
| `show` renderizado com glow e navegação de backup | `lib/16-view.bash` | `lib/03-store.bash` (`cmd_show` cru interno), `lib/17-open.bash`, `tests/view.bats`, `tests/nav.bats` |
| Listagem (`tree`, `--flat`) | `lib/15-tree.bash` | `extensions/npass-import` e `extensions/npass-audit` (usam `tree --flat`), `tests/tree.bats` |
| Senhas de backup (`backup`, anexos cifrados) | `lib/13-backup.bash` | `lib/03-store.bash` (cascata em `rm`/`mv`), `lib/06-update.bash`, `extensions/npass-audit`, `tests/backup.bats` |
| Assinatura de identidades/artefatos | `lib/10-signing.bash` | `tests/signing.bats` |
| Sistema de extensões | `lib/11-extensions.bash` | `extensions/`, testes de extensão |
| Importação de outros gerenciadores e conversão do formato antigo (`import npass-legacy`) | `extensions/npass-import` | `tests/import*.bats`, `tests/import-legacy.bats` |
| Passkeys / WebAuthn (backend, índice, blobs) | `extensions/npass-passkey` | `tests/passkey.bats`, `npass-passkey-arquitetura.md` |
| Daemon FIDO2/CTAP2/UHID (Rust) | `passkey/src/` | `passkey/tests/e2e.rs`, `passkey/Cargo.toml` |
| Clipboard X11 | `extensions/npass-clip-x11.bash` | `tests/clip-ext.bats` |
| Clipboard Windows | `extensions/npass-wclip.bash` | `windows_Requisitos.md`, `tests/clip-ext.bats` |
| Instalação | `install.sh` | `tests/install.bats`, `lib/11-extensions.bash` |
| Build do executável | `build.sh` | `lib/*.bash`, `tests/install.bats` |
| Testes de uma funcionalidade | `tests/<funcionalidade>.bats` | implementação correspondente |
| Empacotamento Arch | `packaging/PKGBUILD` | `install.sh`, `build.sh` |
| Documentação pública | `README.md`, `man/npass.1` | implementação/testes somente para verificar fatos |
| Requisitos Windows | `windows_Requisitos.md` | `extensions/npass-wclip` |

## Cadeia de dependência conceitual

```text
bin/npass
   |
   v
lib/00-main.bash
   |
   +--> 01-common.bash
   +--> 02-identity.bash
   +--> 03-store.bash
   +--> 04-clipboard.bash
   +--> 05-otp.bash
   +--> 06-update.bash
   +--> 07-git.bash
   +--> 09-i18n.bash
   +--> 10-signing.bash
   +--> 11-extensions.bash
   +--> 12-diceware.bash
   +--> 13-backup.bash
   +--> 18-help.bash
   +--> 17-open.bash
   +--> 16-view.bash
   +--> 15-tree.bash
   +--> 14-entry.bash   (formato md1: usado por 03, 04, 05, 06, 08, 12)
             |
             +--> extensions/*
             |
             +--> tests/*

build.sh ---> gera bin/npass a partir de lib/
```

## Regras para agentes

1. `bin/npass` é artefato gerado. Não editar diretamente.
2. Alterações de implementação devem partir de `lib/` ou de `extensions/`.
3. Depois de alterar `lib/`, executar `./build.sh` antes de validar o executável.
4. Ao alterar uma funcionalidade, localizar primeiro o teste correspondente em `tests/`.
5. Não modificar fixtures GPG só para fazer um teste passar sem entender o motivo.
6. Em segurança, distinguir claramente comportamento observado de inferência.
7. Não assumir que uma função em outro módulo pode ser alterada sem verificar seu contrato.
8. **O conteúdo de uma entrada é md1 e só `lib/14-entry.bash` o interpreta.** Nenhum outro módulo (nem extensão em shell) pode ler "a 1ª linha", casar `chave: valor` ou procurar `otpauth://` por conta própria: use `npass_entry_load`/`_require`/`_render` no core e `npass get` nas extensões. As exceções são os dois conversores em Python (`extensions/npass-import`, `extensions/npass-audit`), que espelham as regras e são cruzados com o parser do core em `tests/import-legacy.bats`. Mudou o formato? Mude os três e os testes juntos.
9. Não existe leitura do formato antigo no core: entrada em texto puro é recusada com instrução para `npass import npass-legacy ID`.
10. Documentação deve refletir o comportamento real, não uma intenção futura.
11. `pin.md` e `diceware.md` ficam fora deste índice de trabalho conforme solicitado.
12. Comando ou extensão novos entram em `npass_help_data` (`lib/18-help.bash`), numa categoria e seção: `tests/help.bats` falha se ficarem de fora. O menu principal (`npass_help_essential`) é escolha, não lista completa: não acrescente nada ali sem tirar outra coisa.

## Fluxo recomendado

```text
tarefa
  -> este AGENTS.md
  -> AGENTS.md do diretório
  -> arquivo responsável
  -> teste correspondente
  -> dependência direta, se necessária
  -> build/teste
```
