# AGENTS.md - extensions

## Escopo

Extensões opcionais executadas pelo sistema de extensões do `npass`.

As extensões são separadas do core e possuem contrato próprio. O core fornece contexto como `NPASS_STORE`, `NPASS_GPG`, `NPASS_LANG` e `NPASS_BIN`.

## Arquivos

### `npass-import`

Importação de dados de outros gerenciadores e layouts compatíveis.

Use para tarefas envolvendo:

- Bitwarden;
- KeePass/KeePassXC;
- Firefox;
- Chrome;
- LastPass;
- 1Password;
- Aegis;
- andOTP;
- CSV genérico;
- `pass`;
- `pass-secrets`;
- `npass-legacy`: converte, no próprio store, as entradas do formato antigo (texto puro) para md1.

Todo import grava **md1** (`render()` / `render_md1()`); o corpo dos stores `pass` passa por `legacy_to_md1()` e por `verify_conversion()`, que reprova a conversão que perder ou duplicar uma linha. `parse_md1()` aqui e em `npass-audit` espelha `lib/14-entry.bash`: mudou o formato, mude os três.

Testes relacionados: `tests/import.bats`, `tests/import-pass.bats`, `tests/import-pass-secrets.bats`, `tests/import-legacy.bats`.

### `npass-passkey`

Backend de passkeys (`Fido/.map`, `Fido/*.gpg`), verificação, `serve` do helper Rust (`passkey/`) e `seal`.

Teste: `tests/passkey.bats`. Daemon: `passkey/AGENTS.md`. Único `npass-*` que dispara `cargo` no `install.sh` (cabeçalho `npass-extension-cargo`).

### `npass-clip-x11.bash`

Clipboard X11 usando `xclip`.

Use para:

- seleção CLIPBOARD;
- expiração/limpeza;
- comportamento do comando `clip-x11`.

Não interpreta a entrada: chama `"${NPASS_BIN:-npass}" get [CAMPO] ID CAMINHO` e copia o que o core devolve (o formato md1 só é lido em `lib/14-entry.bash`).

Teste principal: `tests/clip-ext.bats`.

### `npass-wclip`

Clipboard Windows usando `wclip`.

Uso documentado inclui senha, campo específico e entrada inteira. O script obtém a entrada por `npass show` e resolve campos localmente. fileciteturn0file0L80-L104

Requisitos e detalhes específicos de Windows: `windows_Requisitos.md`.

## Cadeia de leitura

```text
extensão
  -> lib/11-extensions.bash
  -> teste correspondente
  -> documentação correspondente
```

Para importação:

```text
extensions/npass-import
  -> tests/import.bats
  -> tests/import-pass.bats
  -> tests/import-pass-secrets.bats
```

Não leia todas as extensões para alterar uma única extensão.
