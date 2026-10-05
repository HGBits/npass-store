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
| `signing.bats` | assinatura |
| `update.bats` | atualização/rotação |
| `store-extras.bats` | comportamentos extras do store |
| `i18n.bats` | internacionalização |
| `patch-m2.bats` | regressão/patch específico |

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
