# AGENTS.md - tests

## Escopo

Testes Bats do projeto. Use-os como índice de comportamento esperado antes de abrir toda a implementação.

## Mapa

| Teste | Área |
|---|---|
| `identity.bats` | identidades |
| `install.bats` | instalação (inclui `npass-tui`: release assinado de mentira, verificação GPG, adulteração, chave errada/dupla/ausente) |
| `install-ext.bats` | instalação compartilhada XDG, chave pública de confiança, recusa de artefatos sem assinatura ou assinados por terceiros, desinstalação |
| `install-passkey.bats` | garante que o instalador não compila helpers nem aceita extensões passkey sem assinatura oficial |
| `extensions.bats` | execução/contrato de extensões |
| `batch-ext.bats` | execução em lote de extensões |
| `otp.bats` | OTP |
| `readonly-store.bats` | leitura com o store somente leitura: `get`, `otp` (TOTP) e a falha do HOTP sem imprimir código (pulado como root) |
| `pin.bats` | PIN (`--password`, `--field`) |
| `help.bats` | `help`: menu enxuto, categorias e seções, e guardas (todo comando despachado e toda extensão têm ajuda; dados bem formados) |
| `nav.bats` | navegação de backup no `show` renderizado: `Backup:`/`Entrada:`, par completo, renomeação, nomes difíceis, round-trip com `open` |
| `open.bats` | `open`: codificação de URL, parser estrito, confirmação antes de decifrar, só mostra, lançamento de terminal (sempre falso), `--pause` |
| `view.bats` | `show` renderizado: quando renderiza (TTY real via pty), o que o glow recebe, glow ausente/falhando, anexos |
| `ls.bats` | `ls`: desenho, `--flat`, prefixo por componente, `[backup]`, erros e o aviso do `tree` antigo |
| `entry-md1.bats` | formato md1 (contrato, preservação, recusa de entradas fora de md1 em todos os comandos), `get`, OTP e `audit` |
| `backup.bats` | `backup` e a cascata dos anexos em `rm`, `mv`, `update` e `audit` |
| `signing.bats` | assinatura |
| `update.bats` | atualização/rotação |
| `store-extras.bats` | comportamentos extras do store |
| `i18n.bats` | internacionalização |
| `patch-m2.bats` | regressão/patch específico |
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

Os testes das extensões (import, passkey, clipboard, audit) moram no repositório `npass-extensions`. Os testes daqui que precisam de uma extensão real usam `npass_test_ext_src` (helper): copiam `../npass-extensions` (ou `NPASS_TEST_EXT_REPO`) e são PULADOS se ele não existir.
