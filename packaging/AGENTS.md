# AGENTS.md - packaging

## Escopo

Arquivos de empacotamento do projeto.

## Arquivo

- `PKGBUILD`
- `npass-open.desktop.in` (modelo do handler `x-scheme-handler/npass`; o `install.sh` troca `@NPASS@` pelo caminho absoluto do binário)

## Quando consultar

Use este diretório para tarefas relacionadas a:

- Arch Linux/AUR;
- dependências de pacote;
- instalação via pacote;
- caminhos de instalação;
- integração entre build e pacote.

Para mudanças no instalador em si, consulte `install.sh` e `tests/install.bats`.
