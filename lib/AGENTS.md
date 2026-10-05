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
| `09-i18n.bash` | mensagens/traduções |
| `10-signing.bash` | assinatura e verificação |
| `11-extensions.bash` | descoberta, instalação e execução de extensões |

## Como localizar

- Problema de `init`, identidade ou `.gpg-id` -> `02-identity.bash`
- Problema de `insert/show/ls/edit/rm/mv` -> `03-store.bash`
- Problema envolvendo `.map.gpg` ou nomes de blobs -> `03-store.bash`
- Problema de clipboard padrão -> `04-clipboard.bash`
- Problema de OTP -> `05-otp.bash`
- Problema de update/rotação -> `06-update.bash`
- Commit automático/histórico -> `07-git.bash`
- Texto traduzido -> `09-i18n.bash`
- Assinatura -> `10-signing.bash`
- Extensões -> `11-extensions.bash`

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
