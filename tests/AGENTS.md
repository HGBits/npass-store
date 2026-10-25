# AGENTS.md - tests

## Escopo

Testes Bats do projeto. Use-os como índice de comportamento esperado antes de abrir toda a implementação.

## Mapa

| Teste | Área |
|---|---|
| `identity.bats` | identidades |
| `install.bats` | instalação |
| `install-ext.bats` | instalação de extensões |
| `extensions.bats` | execução/contrato de extensões |
| `batch-ext.bats` | execução em lote de extensões |
| `import.bats` | importação genérica |
| `import-pass.bats` | importação de `pass` |
| `import-pass-secrets.bats` | importação de `pass-secrets` |
| `otp.bats` | OTP |
| `readonly-store.bats` | leitura com o store somente leitura: `get`, `otp` (TOTP) e a falha do HOTP sem imprimir código (pulado como root) |
| `pin.bats` | PIN (`--password`, `--field`) |
| `help.bats` | `help`: menu enxuto, categorias e seções, e guardas (todo comando despachado e toda extensão têm ajuda; dados bem formados) |
| `nav.bats` | navegação de backup no `show` renderizado: `Backup:`/`Entrada:`, par completo, renomeação, nomes difíceis, round-trip com `open` |
| `open.bats` | `open`: codificação de URL, parser estrito, confirmação antes de decifrar, só mostra, lançamento de terminal (sempre falso), `--pause` |
| `view.bats` | `show` renderizado: quando renderiza (TTY real via pty), o que o glow recebe, glow ausente/falhando, anexos |
| `ls.bats` | `ls`: desenho, `--flat`, prefixo por componente, `[backup]`, erros e o aviso do `tree` antigo |
| `entry-md1.bats` | formato md1 (contrato, preservação, recusa de entradas fora de md1 em todos os comandos), `get`, OTP e `audit` |
| `import-convert.bats` | conversão do corpo de stores `pass` para md1 (regras, os dois parsers concordando, `verify_conversion`) e guarda contra o fluxo de migração removido |
| `clip-ext.bats` | `npass-wclip` e `npass-clip-x11` (chamam `npass get`) |
| `backup.bats` | `backup` e a cascata dos anexos em `rm`, `mv`, `update` e `audit` |
| `signing.bats` | assinatura |
| `update.bats` | atualização/rotação |
| `store-extras.bats` | comportamentos extras do store |
| `i18n.bats` | internacionalização |
| `patch-m2.bats` | regressão/patch específico |
| `passkey.bats` | `npass-passkey`: armazenamento, integridade, helper assinado, instalação, PIN/política/bloqueio, ciclo CTAP2 (usa `cargo test`) |
| `diceware.bats` | `diceware`, `memorable`, lista de palavras, sorteio sem viés, instalação da lista |

## Fixtures GPG

- `gnupg_test/`: ambiente de chaves para testes normais.
- `gnupg_atacante/`: ambiente separado para cenários de chave não confiável/atacante.

Não altere chaves ou fixtures sem motivo de teste explícito.

## Regra

Para investigar uma falha:

```text
teste que falhou
  -> função/fluxo chamado pelo teste
  -> módulo responsável
  -> dependência direta
```

Não comece lendo todos os módulos.
