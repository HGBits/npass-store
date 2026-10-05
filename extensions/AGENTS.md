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
- `pass-secrets`.

Testes relacionados: `tests/import.bats`, `tests/import-pass.bats`, `tests/import-pass-secrets.bats`.

### `npass-clip-x11.bash`

Clipboard X11 usando `xclip`.

Use para:

- seleção CLIPBOARD;
- expiração/limpeza;
- parsing de campos;
- comportamento do comando `clip-x11`.

Teste principal: `tests/extensions.bats`.

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
