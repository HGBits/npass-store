#!/usr/bin/env bash
# npass help - ajuda em dois niveis: o menu principal so tem o essencial; o resto
# fica em categorias, e cada categoria tem secoes.
#
#   npass help                     essencial + lista de categorias
#   npass help CATEGORIA           a categoria inteira, com as secoes
#   npass help CATEGORIA SECAO     so uma secao (ex.: npass help gerar frases)
#   npass help todos               todas as categorias, uma depois da outra
#
# TODO o texto de categoria vive em npass_help_data, num formato so:
#   @cat  slug|descricao curta           abre uma categoria
#   @sub  slug|Titulo da secao           abre uma secao dentro dela
#   (demais linhas)                      o conteudo da secao, ja indentado
# O menu principal, a lista de categorias, as paginas e `help todos` saem todos
# dai: nao ha como o menu listar uma categoria que nao existe, nem uma pagina
# ficar sem estar no `help todos`. O que e "essencial" fica em
# npass_help_essential (nao e derivado: e uma escolha).
#
# Ao adicionar um comando: ponha-o numa secao de npass_help_data. tests/help.bats
# falha se um comando despachado em 00-main.bash nao aparecer em `help todos`.

npass_help_essential() {
	cat <<'EOF'
Essencial:
  init ID RECIPIENT...     cria uma identidade nova
  tree [--flat] ID [DIR]   lista as entradas (árvore)
  show ID DIR/PASS         mostra uma entrada (no terminal, renderizada pelo glow)
  clip [CAMPO] ID DIR/PASS copia a senha, ou um campo
  insert [-f] ID DIR/PASS  insere ou atualiza uma entrada
  generate ID DIR/PASS [LEN]   gera uma senha aleatória
  edit ID DIR/PASS         edita uma entrada no $EDITOR
  rm [-f] ID DIR/PASS      remove uma entrada
  mv ID DIR/PASS DEST      renomeia ou move
  otp ID DIR/PASS          código OTP (TOTP/HOTP) da entrada
EOF
}

npass_help_data() {
	cat <<'EOF'
@cat entradas|Ver, escrever, mover e remover entradas
@sub ver|Ver
  tree [--flat] ID [DIR]   árvore dos caminhos lógicos de uma identidade (--flat: um por linha)
  show [--raw|--render] ID DIR/PASS   mostra uma entrada (em terminal: markdown renderizado
                           pelo glow; em pipe: o documento md1 cru)
  clip [CAMPO] ID DIR/PASS copia a senha (padrão), 'all' ou um campo '- chave: valor'
  get [CAMPO] ID DIR/PASS  imprime (em vez de copiar) o mesmo valor que o clip copiaria
@sub escrever|Escrever
  insert [-f] ID DIR/PASS  insere/atualiza uma entrada (alias: add)
  insert --batch [-f] ID   grava várias (registros CAMINHO\0DOCUMENTO-MD1\0 no stdin)
  edit ID DIR/PASS         edita o documento md1 da entrada no $EDITOR
@sub mover|Mover e remover
  mv ID DIR/PASS DEST      renomeia (mesma identidade) ou move (entre identidades) (alias: rename)
  rm [-f] ID DIR/PASS      remove uma entrada (alias: remove, delete)
@sub massa|Em massa
  update [opts] ID PATTERN...   rotaciona senhas em massa (veja 'npass update -h')

@cat gerar|Gerar senhas, frases e PINs
@sub aleatoria|Senha aleatória
  generate [-n|-c|-f] [--in-place] ID DIR/PASS [LEN]   gera uma senha aleatória (alias: gen)
@sub frases|Frases
  diceware [-c|-f] [--in-place] [-s SEP] ID DIR/PASS [N]
                           frase de N palavras (EFF Large); mostra as ALTURAS para anotar
  memorable [-c|-f] [--in-place] [-s SEP] [-l short|short1|short2] ID DIR/PASS [N]
                           frase memorável (palavras curtas), sem alturas
@sub pin|PIN numérico
  pin (--password|--field) [-c|-f] [--in-place] ID DIR/PASS [N]
                           gera um PIN: como a senha da entrada ou como o campo '- pin:'

@cat otp|Códigos de uso único (TOTP/HOTP)
@sub codigo|Gerar o código
  otp ID DIR/PASS          gera o código OTP (TOTP/HOTP) da entrada
  otp clip ID DIR/PASS     copia o código OTP para a área de transferência
@sub cadastro|Cadastrar o segredo
  otp insert [-f] ID DIR/PASS   insere/atualiza a URI OTP (interativo) (alias: add)
  otp uri [-c|-q] ID DIR/PASS   mostra a URI OTP, copia, ou exibe QR
  otp validate URI         confere se uma URI otpauth:// é válida (não toca o store)

@cat backup|Senhas de backup e navegação por links
@sub gravar|Gravar senhas de backup
  backup [-f] -n N ID DIR/PASS   grava N senhas de backup (interativo) num arquivo cifrado
                           anexo à entrada: Backup-X.md (ponteiro) e Backup-X.dados.md (as senhas)
@sub navegar|Navegar entre a entrada e o backup
  open [--here] [--pause] npass://ID/DIR/PASS   segue um link npass:// (só mostra; pede confirmação)
  No 'show' renderizado a entrada ganha 'Backup: [nome](npass://...)' e o anexo ganha
  'Entrada: [nome](npass://...)'; os links são calculados na hora, não ficam gravados.

@cat buscar|Procurar entradas
@sub caminhos|Por caminho
  find ID PADRÃO           busca caminhos lógicos que casam PADRÃO
  tree [--flat] ID [DIR]   árvore (ou, com --flat, a lista) dos caminhos sob DIR
@sub conteudo|Por conteúdo
  grep ID [OPÇÕES] PADRÃO  decifra e busca PADRÃO no conteúdo de cada entrada

@cat identidades|Identidades e assinaturas
@sub criar|Criar
  init ID RECIPIENT...     cria uma identidade nova
  init --sign[=KEYID] ID RECIPIENT...   idem, já assinando o .gpg-id
@sub listar|Listar
  identities               lista as identidades e quantas senhas cada uma tem (alias: ids)
@sub assinar|Assinar
  sign ID [KEYID]          assina (ou reassina) o .gpg-id de uma identidade

@cat git|Histórico no Git
@sub passthrough|Passthrough
  git ARGS...              passthrough para git dentro do store (repositório criado no primeiro init)
@sub historico|Histórico
  log                      mostra os 20 últimos commits em formato resumido
  loglong                  mostra arquivos modificados nos últimos 6 meses

@cat extensoes|Extensões
@sub gerenciar|Gerenciar
  extension sign CAMINHO [KEYID]   assina um executável de extensão
  extension list           lista extensões e se cada uma passaria nas checagens
@sub disponiveis|Disponíveis (instale com ./install.sh --extensions-only)
  import                   importa de outros gerenciadores e de stores pass (npass import --help)
  audit                    audita senhas por vazamentos, força e reutilização
  passkey                  passkeys (WebAuthn/FIDO2) guardadas só no npass
  clip-x11                 copia senha ou campo para o clipboard do X11 (xclip)
  wclip                    copia senha ou campo para o clipboard do Windows
EOF
}

# npass_help_slugs [CATEGORIA] -> slugs (categorias, ou as secoes de CATEGORIA).
npass_help_slugs() {
	npass_help_data | awk -F'|' -v cat="${1-}" '
		/^@cat /  { c = substr($1, 6); if (cat == "") print c; next }
		/^@sub /  { if (c == cat) print substr($1, 6) }'
}

# npass_help_render [CATEGORIA [SECAO]] -> a pagina (ou so a secao). Sem argumentos
# imprime TODAS as categorias. 1 se nada casou.
npass_help_render() {
	npass_help_data | awk -F'|' -v want="${1-}" -v sub_want="${2-}" '
		/^@cat / {
			c = substr($1, 6); desc = $2
			in_cat = (want == "" || c == want)
			in_sub = 0; nsub = 0
			if (in_cat) {
				if (found) print ""
				found = 1
				print "npass help " c ((sub_want != "") ? " " sub_want : "") " - " desc
				print ""
			}
			next
		}
		/^@sub / {
			s = substr($1, 6); title = $2
			in_sub = in_cat && (sub_want == "" || s == sub_want)
			if (in_sub) { if (nsub++) print ""; print title; matched = 1 }
			next
		}
		in_sub && $0 != "" { print }
		END { exit (found && (sub_want == "" || matched)) ? 0 : 1 }'
}

cmd_help() {
	local topic="${1-}" sec="${2-}"
	case "$topic" in
	'')
		printf 'npass %s - Wayland-native password store com resolução de identidade\n\n' "$NPASS_VERSION"
		printf 'Uso: npass COMANDO ID DIR/PASS [...]\n\n'
		npass_help_essential
		printf '\nMais ajuda (npass help CATEGORIA):\n'
		npass_help_data | awk -F'|' '/^@cat /{ printf "  %-12s %s\n", substr($1, 6), $2 }'
		printf '\n  npass help CATEGORIA SECAO   só uma seção (ex.: npass help gerar frases)\n'
		printf '  npass help todos             todos os comandos, por categoria\n'
		printf '\nNão existe modo de caminho físico "clássico": todo comando exige ID.\n'
		;;
	todos | all | tudo)
		npass_help_render
		;;
	*)
		if ! npass_help_slugs | grep -qx -- "$topic"; then
			npass_die "$(npass_t erro_ajuda_categoria "$topic" "$(npass_help_slugs | paste -sd' ')")"
		fi
		if [[ -n "$sec" ]] && ! npass_help_slugs "$topic" | grep -qx -- "$sec"; then
			npass_die "$(npass_t erro_ajuda_secao "$sec" "$topic" "$(npass_help_slugs "$topic" | paste -sd' ')")"
		fi
		npass_help_render "$topic" "$sec"
		if [[ -z "$sec" ]]; then
			printf '\n  Uma seção só: npass help %s SECAO   (%s)\n' "$topic" "$(npass_help_slugs "$topic" | paste -sd' ')"
		fi
		;;
	esac
}
