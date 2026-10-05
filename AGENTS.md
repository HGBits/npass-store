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
| Clipboard Wayland | `lib/04-clipboard.bash` | extensão correspondente se backend externo |
| OTP/TOTP/HOTP | `lib/05-otp.bash` | `tests/otp.bats` |
| Atualização/rotação | `lib/06-update.bash` | `lib/03-store.bash`, testes |
| Git automático | `lib/07-git.bash` | `tests/update.bats`, `tests/store-extras.bats` |
| Internacionalização | `lib/09-i18n.bash` | `tests/i18n.bats` |
| Assinatura de identidades/artefatos | `lib/10-signing.bash` | `tests/signing.bats` |
| Sistema de extensões | `lib/11-extensions.bash` | `extensions/`, testes de extensão |
| Importação de outros gerenciadores | `extensions/npass-import` | `tests/import*.bats` |
| Clipboard X11 | `extensions/npass-clip-x11.bash` | `tests/extensions.bats` |
| Clipboard Windows | `extensions/npass-wclip` | `windows_Requisitos.md`, `tests/extensions.bats` |
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
8. Documentação deve refletir o comportamento real, não uma intenção futura.
9. `pin.md` e `diceware.md` ficam fora deste índice de trabalho conforme solicitado.

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
