# npass-passkey: arquitetura e decisões

```text
Browser -> WebAuthn/FIDO2 -> npass-passkeyd (CTAP2 + UHID, Rust, soft-fido2)
        -> `npass passkey ...` (extensions/npass-passkey, bash) -> npass (GPG)
                                   ├── ID/Fido/.map     descoberta
                                   └── ID/Fido/*.gpg    credencial
```

## Responsabilidades
- **npass-passkeyd** (`passkey/`): CTAP2, CTAPHID, UHID, confirmação de presença. Nada em disco.
- **npass-passkey** (`extensions/npass-passkey`): blobs, índice, lock, verificação, `serve`, `seal`.
- **npass**: recipients (`.gpg-id`, assinado se `.gpg-id.sig`), GPG, git, portas de extensão.

## Formatos (decisões onde a especificação deixava aberto)
- Linha de cabeçalho do blob: `chave<TAB>valor` (rp_id/login não podem ter controles).
- `payload-sha256` = sha256 dos bytes armados (ASCII armor) que seguem o cabeçalho.
- Assinatura = GPG destacada sobre as 4 primeiras linhas (magic, rp_id, login, payload-sha256), em base64.
- Payload cifrado repete `rp_id`/`login` e leva a credencial (CBOR do soft-fido2, base64);
  `load`/`verify --deep` exigem que batam com o cabeçalho público.
- Chave **autorizada** = chave primária de algum recipient do `.gpg-id`. Assina-se com uma chave secreta
  sua que esteja entre eles.
- Nome do blob: 32 hex aleatórios + `.gpg`. `.map`: `# npass-fido-map-v2`, `# rp_id<TAB>login<TAB>blob`.
- Interface `store`: credencial em **base64** no stdin (bash não carrega binário).
- Ordem de escrita: blob, depois índice (falhou: blob revertido). `rm`: índice, depois blob. Uma queda
  no meio deixa um **órfão** (detectado por `verify`, curado por `rebuild-index`), nunca entrada pendurada.
- Duplicata = mesmo payload em dois blobs, mesma credencial (`--deep`) ou blob duas vezes no índice.
  Mesmo RP/login com credenciais diferentes é válido.

## Daemon
- `read_credential(id)`: o id está dentro do payload cifrado, então o daemon guarda só um mapa **volátil**
  id->blob e, se não achar, abre os blobs até achar (com cooldown de 5 s contra varreduras repetidas).
  `list_credentials(rp)` abre só os blobs que o índice aponta para aquele RP.
- Contador de assinaturas constante (0): login não regrava blob. Algoritmo: ES256.
- UV = confirmação explícita + pinentry do GPG ao decifrar. Não há biometria. Sem diálogo disponível, **nega**.
- Chama sempre `$NPASS_BIN passkey ...`, então cada operação passa de novo pelas portas de extensão do npass.
- CTAPHID keepalive não é enviado: o diálogo bloqueia o loop; o navegador pode expirar se você demorar.

## PIN e política (por identidade, tudo em `Fido/`)
- `.pin.gpg`: `NPASS-FIDO-PIN-V1` + `policy` (+ `salt`/`hash` se houver PIN), **cifrado e assinado** por chave
  autorizada (mesmo critério dos blobs). Só quem tem a chave lê; quem só escreve no store não troca PIN nem política.
  Hash = sha256(salt:PIN), uma rodada: a proteção contra força bruta é a cifra GPG + o limite de 5 erros, não o hash.
- `.pin-tries`: erros consecutivos, 0600. Sobe **antes** de comparar, zera no acerto, 5 = bloqueado.
  Não vai ao git (e `.map.lock` também não); é estado local da máquina.
- PIN: `^[A-Za-z0-9]{4,64}$`. O mínimo de 4 é decisão minha (o mesmo piso do CTAP).
- Política: `nunca` (não pede PIN), `opcional` (padrão: pede se houver PIN e o site pedir UV), `requerido`
  (toda operação, UP e UV; sem PIN, nega). Mudar a política ou o PIN com PIN definido exige o PIN atual
  (conta como tentativa) ou `--gpg`.
- `--gpg` = prova da chave: esquece a passphrase em cache das chaves da identidade no gpg-agent
  (`clear_passphrase`) e exige assiná-la de novo num desafio. Chave sem passphrase: a prova é só a posse.
- `.pin.gpg` apagado com o contador presente, ou trocado por registro sem assinatura autorizada: tratado
  como **bloqueado** (não rebaixa a política). `pin set --gpg` recupera (a política volta a `opcional`).
- Daemon: antes de cada UP/UV lê `pin status`; se a política pede PIN, pergunta (zenity/kdialog/tty/`--pin-cmd`)
  e confere com `pin verify` (stdin, nunca argv). PIN certo vale para o mesmo RP por 15 s (UV seguido de UP).
- A biblioteca marca como "UV obrigatório" (credProtect 3) as credenciais criadas numa cerimônia com UV, e
  criar passkey descobrível já implica UV: com PIN definido, o registro pede o PIN mesmo em `opcional`, e um
  site que não peça UV não acha a credencial. Navegadores pedem UV, então na prática o PIN aparece em `opcional`.

## Segurança do helper
`serve` exige: diretório de helpers seu e sem escrita de grupo/outros; helper e selo regulares (não links),
com `.sig` válida de uma chave **secreta sua**; selo com protocolo igual, sha256 do helper e sha256 desta
extensão iguais aos atuais. Binário antigo (ainda assinado), adulterado ou de outra versão é recusado.
Resíduo: checagem e `exec` não são atômicos (mesma limitação do sistema de extensões); o diretório 0700 o reduz.

## Instalação
`install.sh`, só ao escolher `npass-passkey` (cabeçalho `npass-extension-cargo`): confere o cargo do usuário
que roda o npass, apaga qualquer binário anterior, compila `passkey/` com `--locked`, exige binário novo,
instala o helper, assina a extensão e roda `npass passkey seal`. Falhou o cargo: nada é instalado.

## Limites conhecidos
- O PIN é verificado no backend/daemon, não envolve a credencial criptograficamente: quem roda como o seu
  usuário e tem o gpg-agent destravado ainda pode chamar `npass passkey load` direto. Ele barra páginas web
  e processos que só falam WebAuthn/UHID, não malware no seu uid. Apagar `Fido/.pin*` junto (sem deixar
  contador) também volta ao padrão `opcional`.
- O contador é local (fora do git): clonar o store em outra máquina dá 5 tentativas novas lá.
- Não testado com navegador real/UHID neste ambiente (sem `/dev/uhid`); o ciclo CTAP2 é testado em
  processo (`passkey/tests/e2e.rs`) com assinatura ES256 verificada contra o npass real.
- `rp_id`/`login` em claro (índice, cabeçalhos, git). Não há proteção contra rollback para blob antigo
  válido (o git do store é o histórico).
- Sem `credentialsd`; a futura ponte usará os mesmos comandos `npass passkey`.
