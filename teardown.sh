#!/usr/bin/env bash
# =============================================================================
#  teardown.sh — DESTRUIÇÃO SEGURA do servidor de ensaio
#  Roda SÓ no servidor descartável, ANTES de deletar a VM no painel.
# =============================================================================
#  Por que existe: o descartável segurou a joia da coroa — todos os bancos (com
#  dados de cliente), todos os segredos (.env, tokens de WhatsApp/Meta/Google),
#  a chave da CA do Ankh, e as senhas do backup que você digitou. Deletar a VM
#  desaloca o disco, mas o provedor nem sempre zera na hora: um disco reusado
#  pode, em teoria, guardar restos. Aqui a gente SOBRESCREVE antes de destruir.
#
#  USO:
#     bash teardown.sh check     → lista o que será destruído (não apaga nada)
#     bash teardown.sh wipe      → destrói de verdade (pede confirmação)
#
#  DEPOIS de rodar o wipe: delete a VM pelo painel da Netcup e confirme.
# =============================================================================
set -uo pipefail

ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
inf(){ printf '  · %s\n' "$1"; }
sec(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

[ "$(id -u)" = 0 ] || { echo "precisa de root"; exit 1; }

# Trava: nunca rodar em produção.
if [ ! -f /root/.dr-drill ]; then
  cat >&2 <<'EOF'
✗ RECUSADO: marcador de ensaio ausente (/root/.dr-drill).
  Este script DESTRÓI dados. Só roda no servidor descartável, que deve ser
  marcado logo após o restore com:   touch /root/.dr-drill
EOF
  exit 1
fi

# Alvos: segredos (sobrescrever) e dados (apagar)
SEGREDOS=(/opt/ankh/pki /opt/ankh/data /opt/thoth/data /opt/thoth-mcp/.thoth_creds
          /opt/thoth-mcp/.connector_pass /opt/thoth-mcp/.oauth_store.json
          /opt/horus-backup/restic.env /opt/horus-backup/sb_key
          /root/.ssh /home/ubuntu/.ssh /root/.claude)
ENVS=(/home/ubuntu/horus/.env /home/ubuntu/horus-saas/.env /opt/alphavip/.env /opt/studio/.env)
DADOS=(/home/ubuntu/hdrive /home/ubuntu/uploads /opt/horus-backup/staging)
HIST=(/root/.bash_history /home/ubuntu/.bash_history /root/.mysql_history)

do_check(){
  sec "Segredos que serão SOBRESCRITOS (shred)"
  for p in "${SEGREDOS[@]}" "${ENVS[@]}"; do [ -e "$p" ] && inf "$p ($(du -sh "$p" 2>/dev/null | cut -f1))"; done
  sec "Dados que serão APAGADOS"
  for p in "${DADOS[@]}"; do [ -e "$p" ] && inf "$p ($(du -sh "$p" 2>/dev/null | cut -f1))"; done
  sec "Bancos que serão DERRUBADOS"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "db|mysql|postgres" | sed 's/^/  · /'
  systemctl is-active mysql >/dev/null 2>&1 && inf "mysql (nativo)"
  sec "Histórico de shell (apaga — contém as senhas que você digitou)"
  for p in "${HIST[@]}"; do [ -f "$p" ] && inf "$p"; done
  echo; inf "Nada foi alterado. Para destruir: bash teardown.sh wipe"
}

do_wipe(){
  echo "⚠️  Isto DESTRÓI todos os dados e segredos deste servidor, de forma irreversível."
  read -rp "Digite DESTRUIR para confirmar: " C
  [ "$C" = "DESTRUIR" ] || { echo "cancelado"; exit 1; }

  sec "1. Parando serviços (não podem reescrever nada depois)"
  systemctl stop thoth ankh thoth-mcp 2>/dev/null; ok "systemd parado"
  sudo -u ubuntu pm2 delete all >/dev/null 2>&1; ok "pm2 encerrado"

  sec "2. Derrubando bancos COM os volumes (dados vão junto)"
  for d in /opt/alphavip /opt/studio; do
    [ -d "$d" ] && (cd "$d" && docker compose down -v >/dev/null 2>&1) && ok "compose down -v: $d"
  done
  docker volume prune -f >/dev/null 2>&1 && ok "volumes docker removidos"
  if systemctl is-active mysql >/dev/null 2>&1; then
    mysql -e "SHOW DATABASES" 2>/dev/null | grep -vE "^(Database|information_schema|performance_schema|mysql|sys)$" | \
      while read db; do mysql -e "DROP DATABASE \`$db\`" 2>/dev/null && ok "DROP $db"; done
    systemctl stop mysql 2>/dev/null
  fi

  sec "3. Sobrescrevendo segredos (shred — não dá pra recuperar)"
  for p in "${SEGREDOS[@]}" "${ENVS[@]}"; do
    [ -e "$p" ] || continue
    if [ -d "$p" ]; then find "$p" -type f -exec shred -fuz -n 2 {} + 2>/dev/null; rm -rf "$p" 2>/dev/null
    else shred -fuz -n 2 "$p" 2>/dev/null; fi
    ok "destruído: $p"
  done

  sec "4. Apagando dados de cliente"
  for p in "${DADOS[@]}"; do [ -e "$p" ] && rm -rf "$p" 2>/dev/null && ok "removido: $p"; done

  sec "5. Histórico de shell (as senhas que você digitou no ensaio)"
  for p in "${HIST[@]}"; do [ -f "$p" ] && shred -fuz -n 2 "$p" 2>/dev/null && ok "limpo: $p"; done
  history -c 2>/dev/null || true

  sec "6. Sobrescrevendo o espaço livre (restos de arquivos já apagados)"
  inf "pode levar alguns minutos — enche o disco de zeros e apaga"
  dd if=/dev/zero of=/zerofill bs=1M status=none 2>/dev/null; sync; rm -f /zerofill
  ok "espaço livre sobrescrito"

  cat <<'EOF'

  ════════════════════════════════════════════════════════════
   AGORA: delete a VM no painel da Netcup e confirme a exclusão.
   Não reutilize este servidor para outra coisa.
  ════════════════════════════════════════════════════════════
EOF
}

case "${1:-check}" in
  check) do_check ;;
  wipe)  do_wipe ;;
  *) echo "uso: teardown.sh {check|wipe}"; exit 1 ;;
esac
