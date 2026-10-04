# Requisitos para suporte ao Windows

## Objetivo

Este documento registra os requisitos identificados para tornar o `npass` utilizável no Windows, preservando o mesmo formato de armazenamento e evitando criar uma versão separada do projeto.

A análise considera o estado atual do projeto `npass` e a estratégia de suporte ao Windows por meio de um ambiente compatível com Bash, especialmente **Git Bash/MSYS2**, em vez de executar o projeto diretamente em `cmd.exe` ou PowerShell.

A extensão `npass-wclip.bash` resolve a integração com a área de transferência do Windows, mas não resolve sozinha todas as dependências Unix/Linux existentes no núcleo do `npass`.

---

## 1. Estratégia de compatibilidade

A abordagem recomendada é:

- manter o núcleo do `npass` em Bash;
- manter o formato do cofre exatamente igual entre Linux e Windows;
- manter GPG como backend criptográfico;
- utilizar Git para Windows quando o recurso Git estiver habilitado;
- utilizar Git Bash/MSYS2 como ambiente de execução;
- isolar as diferenças específicas do sistema operacional em uma camada de abstração;
- utilizar extensões para recursos que dependem diretamente da plataforma, como clipboard.

### Objetivo arquitetural

Não criar um `npass-windows` separado.

O ideal é que o mesmo código possa executar em Linux e Windows, com diferenças somente nos backends das operações dependentes do sistema.

Isso evita:

- divergência entre versões;
- formatos de armazenamento diferentes;
- correções duplicadas;
- comportamento diferente entre plataformas;
- manutenção de dois núcleos do projeto.

---

# 2. Dependências do ambiente Windows

## 2.1 Bash

O `npass` é implementado em Bash e depende de recursos do shell.

O ambiente Windows precisa fornecer um Bash compatível.

### Ambiente recomendado

- Git Bash; ou
- MSYS2.

A execução diretamente em `cmd.exe` ou PowerShell não é o objetivo desta primeira etapa de compatibilidade.

---

## 2.2 GnuPG

O GPG continua sendo o backend criptográfico do `npass`.

É necessário disponibilizar uma instalação funcional do **GnuPG para Windows**.

A camada criptográfica não precisa ser substituída.

O objetivo é que operações como:

- criptografia;
- descriptografia;
- assinatura;
- verificação de assinatura;

continuem utilizando GPG da mesma maneira que no Linux.

---

## 2.3 Git

O projeto possui integração com Git.

O Git é suportado no Windows através do Git for Windows.

Embora o README trate Git como opcional, o comportamento atual do projeto inicializa e utiliza repositórios Git para as operações correspondentes. Portanto, para reproduzir integralmente o comportamento atual do `npass`, o ambiente Windows deve possuir Git funcional.

---

# 3. Dependências Unix que precisam de atenção

O principal problema da portabilidade não está no formato do cofre nem no GPG. Está nas ferramentas e interfaces Unix utilizadas diretamente pelo código.

## 3.1 `flock`

### Situação

`flock` é utilizado para bloquear recursos durante operações concorrentes.

Esse é um dos pontos que mais claramente precisam ser abstraídos para uma implementação multiplataforma.

O Windows não possui a mesma interface Unix de `flock`.

### Requisito

A operação de lock deve deixar de depender diretamente de `flock` espalhado pelo código.

Recomenda-se criar uma função de abstração, por exemplo:

```bash
npass_lock_acquire
npass_lock_release
```

ou uma interface equivalente.

### Backend Linux

Pode continuar utilizando:

```text
flock
```

### Backend Windows

Deve utilizar um mecanismo compatível disponível no ambiente Windows/MSYS2.

O código que trabalha com o mapa e outros recursos protegidos não deveria precisar saber qual mecanismo de lock está sendo utilizado.

---

## 3.2 `shred`

### Situação

O projeto utiliza `shred` para remoção de arquivos sensíveis.

`shred` é uma ferramenta Unix e não possui o mesmo suporte nativo no Windows.

Além disso, mesmo no Linux, `shred` não deve ser tratado como garantia absoluta de destruição física dos dados em todos os tipos de armazenamento, especialmente SSDs e sistemas de arquivos modernos.

### Requisito

A exclusão segura deve ser abstraída.

Exemplo:

```bash
npass_secure_delete
```

O restante do projeto chama essa função sem conhecer a implementação específica da plataforma.

---

## 3.3 `mktemp`

O projeto utiliza `mktemp` para arquivos temporários.

Git Bash/MSYS2 normalmente fornece ferramentas Unix suficientes para esse uso, mas a criação de arquivos temporários deve ser tratada como uma dependência de plataforma.

Recomenda-se concentrar essa operação em uma função:

```bash
npass_mktemp
```

Isso também permite alterar posteriormente o mecanismo sem modificar todas as funções que precisam de arquivos temporários.

---

## 3.4 Diretório temporário/runtime

O código utiliza conceitos como:

```text
XDG_RUNTIME_DIR
/tmp
```

Esses caminhos são próprios do ambiente Unix.

No Windows, o ambiente MSYS2/Git Bash fornece uma camada de compatibilidade, mas não é desejável depender indefinidamente de caminhos Unix específicos.

Recomenda-se criar uma abstração:

```bash
npass_runtime_dir
```

A resolução pode considerar, em ordem apropriada:

```text
XDG_RUNTIME_DIR
TMPDIR
TEMP
diretório temporário fornecido pelo ambiente
```

O objetivo é impedir que o restante do código precise conhecer as diferenças entre os sistemas.

---

## 3.5 `/dev/urandom`

O projeto utiliza `/dev/urandom` para geração de dados aleatórios.

Dentro de Git Bash/MSYS2 esse tipo de interface Unix pode estar disponível.

Portanto, isso não é necessariamente um bloqueador para a primeira versão Windows.

Mesmo assim, para uma arquitetura multiplataforma mais robusta, recomenda-se abstrair a geração de bytes aleatórios:

```bash
npass_random_bytes
```

Isso permitiria utilizar uma fonte adequada ao sistema operacional sem alterar o código que precisa de aleatoriedade.

---

# 4. Clipboard

## 4.1 Linux/Wayland

O núcleo atual utiliza:

```text
wl-copy
wl-paste
```

Essas ferramentas são específicas de Wayland e não estão disponíveis nativamente no Windows.

---

## 4.2 Windows

A extensão:

```text
npass-wclip.bash
```

foi criada para adaptar o comando `wclip` ao `npass`.

A ideia é manter o núcleo independente do mecanismo de clipboard do Windows.

Exemplos previstos:

```bash
npass wclip ID PATH
npass wclip pass ID PATH
npass wclip FIELD ID PATH
npass wclip all ID PATH
```

A extensão obtém o conteúdo através de `npass show` e entrega o valor ao `wclip` usando o modo de segredo.

### Conclusão

O clipboard do Windows pode ser tratado como uma extensão, sem modificar o armazenamento ou a criptografia do `npass`.

---

# 5. OTP

O suporte a OTP depende de ferramentas externas.

O projeto utiliza ferramentas como:

```text
oathtool
otptool
qrencode
```

É necessário verificar a disponibilidade de versões compatíveis dessas ferramentas no ambiente Windows escolhido.

## Requisitos

Para suporte completo às funcionalidades OTP:

- ferramenta compatível para geração de códigos TOTP/HOTP;
- ferramenta compatível para geração de QR Code;
- execução dessas ferramentas a partir do Bash;
- comportamento de saída compatível com o que o `npass` espera.

Se alguma dessas ferramentas não estiver disponível de forma adequada no Windows, deve ser criada uma camada de compatibilidade ou definida uma dependência específica para o ambiente Windows.

---

# 6. Ferramentas Unix auxiliares

O código utiliza ferramentas comuns do ambiente Unix, incluindo operações equivalentes a:

```text
find
grep
sed
cut
sort
awk
head
od
tr
wc
```

Essas ferramentas normalmente estão disponíveis no Git Bash/MSYS2.

Portanto, elas não representam necessariamente uma alteração de código para a primeira implementação Windows.

Entretanto, elas reforçam a decisão de utilizar um ambiente Bash/MSYS2 em vez de tentar executar o projeto diretamente em `cmd.exe` ou PowerShell.

---

# 7. HOME e PATH

O projeto utiliza conceitos Unix como:

```text
$HOME
$PATH
```

Git Bash/MSYS2 fornece uma camada compatível para esses ambientes.

O diretório padrão do armazenamento:

```text
$HOME/.npass
```

pode permanecer conceitualmente igual.

A variável:

```text
NPASS_STORE
```

continua sendo o mecanismo recomendado para alterar a localização do armazenamento.

Não é necessário criar um formato de armazenamento específico para Windows.

---

# 8. Permissões de arquivos

O projeto utiliza permissões de arquivos Unix para restringir arquivos sensíveis e extensões.

No Windows, o modelo nativo é baseado em ACLs.

Git Bash/MSYS2 fornece uma camada de compatibilidade para operações como:

```text
chmod
```

mas o comportamento não é idêntico ao de um sistema Linux.

Isso é particularmente importante para:

- arquivos de extensões;
- chaves e arquivos auxiliares;
- arquivos temporários;
- verificações de segurança baseadas em permissões.

## Requisito

As verificações de segurança do `npass` devem ser avaliadas em Windows para determinar quais garantias são realmente fornecidas pelo ambiente MSYS2/Git Bash.

Não se deve assumir que uma permissão Unix simulada no Windows oferece exatamente a mesma proteção de uma permissão POSIX real.

---

# 9. Editor

O `npass` pode depender de `$EDITOR` para operações que permitem edição.

Em Git Bash, `$EDITOR` pode apontar para:

- editor de terminal;
- editor instalado no Windows;
- executável acessível pelo `PATH`.

É necessário testar o comportamento quando o editor for um aplicativo gráfico do Windows.

O objetivo é evitar que operações de edição dependam de comportamentos específicos do terminal Linux.

---

# 10. Arquitetura recomendada

Recomenda-se criar uma camada de abstração de plataforma, por exemplo:

```text
lib/06-platform.bash
```

Essa camada concentraria operações dependentes do sistema operacional.

Uma interface inicial poderia conter:

```bash
npass_lock_acquire
npass_lock_release

npass_mktemp

npass_secure_delete

npass_random_bytes

npass_runtime_dir
```

O restante do projeto utiliza essas funções em vez de chamar diretamente ferramentas dependentes da plataforma.

### Exemplo conceitual

Em vez de:

```bash
flock ...
```

usar:

```bash
npass_lock_acquire ...
```

Em vez de:

```bash
shred ...
```

usar:

```bash
npass_secure_delete ...
```

Em vez de depender diretamente de:

```text
/tmp
```

usar:

```bash
npass_runtime_dir
```

Isso cria uma fronteira clara entre:

```text
Lógica do npass
        |
        v
Abstração de plataforma
        |
   +----+----+
   |         |
 Linux    Windows/MSYS
```

---

# 11. Ordem recomendada de implementação

A implementação do suporte Windows pode ser dividida nas seguintes etapas.

## Etapa 1 - Lock

Abstrair:

```text
flock
```

Esse é um dos pontos mais importantes porque envolve concorrência e integridade do armazenamento.

---

## Etapa 2 - Exclusão segura

Abstrair:

```text
shred
```

Criar uma função única para remoção de arquivos sensíveis.

---

## Etapa 3 - Temporários e runtime

Abstrair:

```text
mktemp
XDG_RUNTIME_DIR
/tmp
```

Criar funções centralizadas para diretórios e arquivos temporários.

---

## Etapa 4 - Aleatoriedade

Abstrair o acesso a:

```text
/dev/urandom
```

Isso não é necessariamente necessário para o primeiro protótipo Windows em MSYS2, mas melhora a arquitetura multiplataforma.

---

## Etapa 5 - Dependências externas

Validar no Windows:

```text
GPG
Git
oathtool / otptool
qrencode
```

e documentar exatamente quais pacotes precisam estar instalados.

---

## Etapa 6 - Clipboard

A extensão:

```text
npass-wclip.bash
```

já cobre a integração específica com o clipboard do Windows.

---

## Etapa 7 - Testes

Criar uma matriz de testes executada pelo menos em:

```text
Linux
Windows + Git Bash/MSYS2
```

Os testes devem verificar principalmente:

- criação do store;
- criação de identidade;
- criptografia;
- descriptografia;
- leitura;
- gravação;
- rename;
- move entre identidades;
- geração de senha;
- OTP;
- Git;
- locks concorrentes;
- remoção de arquivos temporários;
- extensões;
- clipboard Windows.

---

# 12. Requisito de compatibilidade do formato

O Windows não deve introduzir um novo formato de armazenamento.

Um store criado no Linux deve poder ser utilizado no Windows e vice-versa, desde que:

- GPG esteja configurado corretamente;
- as identidades/chaves necessárias estejam disponíveis;
- as dependências estejam instaladas;
- o ambiente tenha suporte às operações necessárias.

O objetivo é que a plataforma seja transparente para o formato criptografado.

---

# 13. O que já está resolvido

A extensão:

```text
npass-wclip.bash
```

resolve a integração específica com o `wclip` no Windows.

Isso evita modificar o núcleo do `npass` apenas para implementar uma área de transferência específica da plataforma.

A arquitetura de extensões existente também permite manter esse componente separado do núcleo.

---

# 14. O que ainda precisa ser feito

### Código

- [ ] Abstrair `flock`.
- [ ] Abstrair `shred`.
- [ ] Abstrair criação de temporários.
- [ ] Abstrair diretório runtime.
- [ ] Avaliar abstração de `/dev/urandom`.
- [ ] Verificar todas as chamadas Unix que não sejam fornecidas pelo MSYS2.
- [ ] Validar tratamento de permissões no Windows.

### Dependências

- [ ] GnuPG para Windows.
- [ ] Git for Windows.
- [ ] Bash via Git Bash ou MSYS2.
- [ ] Ferramenta OTP compatível.
- [ ] `qrencode` compatível, caso QR Code seja utilizado.
- [ ] `wclip` para clipboard.

### Testes

- [ ] Testar criação do store.
- [ ] Testar operações criptográficas.
- [ ] Testar identidades.
- [ ] Testar mapa lógico.
- [ ] Testar blobs físicos.
- [ ] Testar rename.
- [ ] Testar move entre identidades.
- [ ] Testar Git.
- [ ] Testar OTP.
- [ ] Testar locks.
- [ ] Testar limpeza de temporários.
- [ ] Testar extensões.
- [ ] Testar clipboard via `wclip`.

### Documentação

- [ ] Documentar instalação no Windows.
- [ ] Documentar instalação do Git Bash/MSYS2.
- [ ] Documentar GPG.
- [ ] Documentar Git.
- [ ] Documentar ferramentas OTP.
- [ ] Documentar `wclip`.
- [ ] Documentar `NPASS_STORE`.
- [ ] Documentar limitações de permissões no Windows.

---

# 15. Resumo

O `npass` não precisa ser reescrito para Windows.

O caminho mais coerente é adicionar uma camada de compatibilidade de plataforma e executar o projeto em um ambiente Bash compatível, principalmente Git Bash/MSYS2.

Os pontos que exigem atenção no código são principalmente:

1. `flock`;
2. `shred`;
3. temporários e diretórios runtime;
4. `/dev/urandom`;
5. permissões de arquivos.

As dependências externas também precisam ser validadas:

1. GPG;
2. Git;
3. ferramentas OTP;
4. `qrencode`;
5. `wclip`.

O armazenamento criptografado, o modelo de identidades e os blobs físicos não precisam de um formato específico para Windows.

A extensão `npass-wclip.bash` já cobre o caso do clipboard Windows. O trabalho restante deve ficar concentrado na camada de plataforma e na validação das dependências.

---

## Referência

Análise baseada no estado atual do projeto `npass-store` e em sua documentação e estrutura de código disponíveis no repositório:

`https://github.com/HGBits/npass-store`

A conclusão central é manter um único `npass`, com o código específico de plataforma isolado em uma camada própria, em vez de criar uma implementação Windows independente.
