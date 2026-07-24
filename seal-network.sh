#!/usr/bin/env bash
# =============================================================================
#  seal-network.sh — LACRE DE REDE para o ensaio de recuperação
#  Roda SÓ no servidor descartável. NUNCA em produção.
# =============================================================================
#  Por que existe: o backup traz credenciais REAIS (WhatsApp Cloud API, Meta CAPI,
#  Google Ads, Shopify, Guru/pagamento, VAPID/push, SMTP). Se os apps subirem com
#  saída livre e processarem a fila do banco, eles vão MANDAR mensagem pra cliente
#  de verdade, disparar push real e poluir os dados de anúncio da produção.
#  Webhooks de ENTRADA não são risco (batem no domínio de prod, IP diferente) —
#  o perigo é tudo que o app ENVIA.
#
#  Duas fases, porque os repositórios são CDN (IP muda, não dá pra fixar):
#     open  → saída HTTPS liberada. Use para provision (baixar pacotes).
#     seal  → saída BLOQUEADA, exceto Storage Box + DNS + seu IP. Use ANTES de
#             subir qualquer app. É o lacre de verdade.
#     status/off
#
#  ORDEM DO ENSAIO:
#     1. seal-network.sh open      → provision (instala pacotes)
#     2. seal-network.sh seal      → LACRA
#     3. dr-restore.sh restaurar   → (Storage Box continua liberado)
#     4. recover.sh dbrestore      → bancos locais, sem rede externa
#     5. recover.sh services       → apps sobem LACRADOS: não alcançam ninguém
# =============================================================================
set -uo pipefail

SB_HOST="u622685.your-storagebox.de"
SB_PORT=23
MODO="${1:-status}"
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
inf(){ printf '  · %s\n' "$1"; }
sec(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

[ "$(id -u)" = 0 ] || { echo "precisa de root"; exit 1; }

# Trava de segurança: se parecer o servidor de PRODUÇÃO, recusa.
if [ -f /opt/horus-backup/backup.sh ] && [ -d /home/ubuntu/horus/.git ] && [ ! -f /root/.dr-drill ]; then
  cat >&2 <<'EOF'
✗ RECUSADO: isto parece o servidor de PRODUÇÃO (backup.sh + repo horus presentes).
  Este script é só para o servidor DESCARTÁVEL do ensaio.
  Se este É o descartável (restaurado do backup), marque-o antes:
      touch /root/.dr-drill
EOF
  exit 1
fi

have_ufw(){ command -v ufw >/dev/null 2>&1; }

do_open(){
  sec "Fase ABERTA — saída HTTPS liberada (para instalar pacotes)"
  have_ufw || { inf "ufw ausente: apt-get install -y ufw"; apt-get install -y -qq ufw >/dev/null 2>&1; }
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw allow 22/tcp >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  ok "entrada bloqueada (exceto SSH), saída LIVRE"
  inf "faça o provision agora — depois rode: seal-network.sh seal"
}

do_seal(){
  sec "Fase LACRADA — saída bloqueada exceto o essencial"
  have_ufw || { echo "  ufw ausente"; exit 1; }
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default deny outgoing >/dev/null 2>&1          # ← o lacre
  ufw allow 22/tcp >/dev/null 2>&1                   # você entra por SSH
  ufw allow out 53 >/dev/null 2>&1                   # DNS (resolver nomes locais)
  # Storage Box: única saída externa permitida (baixar/verificar o backup)
  for ip in $(getent ahostsv4 "$SB_HOST" 2>/dev/null | awk '{print $1}' | sort -u); do
    ufw allow out to "$ip" port "$SB_PORT" proto tcp >/dev/null 2>&1 && ok "saída liberada: Storage Box $ip:$SB_PORT"
  done
  # loopback e rede docker interna continuam funcionando (ufw não bloqueia lo/bridge por padrão)
  ufw --force enable >/dev/null 2>&1
  ok "LACRADO — apps não alcançam WhatsApp, Meta, Google, SMTP nem clientes"
  inf "agora é seguro rodar: recover.sh dbrestore  →  recover.sh services"
}

do_status(){
  sec "Estado do firewall"
  have_ufw && ufw status verbose 2>/dev/null | head -12 | sed 's/^/  /' || inf "ufw não instalado"
  sec "Teste real de saída (deve FALHAR quando lacrado)"
  timeout 6 curl -sS -o /dev/null https://graph.facebook.com 2>/dev/null && echo "  ⚠️ ALCANÇA a Meta — NÃO está lacrado" || ok "não alcança a Meta (lacrado)"
  timeout 6 bash -c "</dev/tcp/$SB_HOST/$SB_PORT" 2>/dev/null && ok "alcança o Storage Box (correto)" || inf "não alcança o Storage Box — libere antes de restaurar"
}

case "$MODO" in
  open)   do_open ;;
  seal)   do_seal ;;
  status) do_status ;;
  off)    ufw --force reset >/dev/null 2>&1; ufw --force disable >/dev/null 2>&1; ok "firewall desligado (só faça isso ao destruir a VM)" ;;
  *) echo "uso: seal-network.sh {open|seal|status|off}"; exit 1 ;;
esac
