#!/usr/bin/env bash
# =============================================================================
#  dr-restore.sh — SEED de recuperação de desastre (Camada 0)
#  idee.haus / Horus — plataforma Netcup
# =============================================================================
#  O que é: o script MÍNIMO para ressuscitar tudo num servidor Ubuntu NOVO e cru.
#  Ele não sabe nada de segredo — as 2 senhas vêm de VOCÊ (do app Senhas do iCloud)
#  e são digitadas na hora, nunca ficam gravadas.
#
#  Ele faz só a Camada 0: instala o restic, conecta no backup e restaura os
#  arquivos. Reimportar bancos, instalar pacotes e subir serviços é a Camada 1
#  (o Ankh em modo-recuperação, que este script deixa restaurado e pronto).
#
#  COMO USAR num servidor novo:
#     1. Entre por SSH como root.
#     2. Baixe este script (do GitHub alpfreitas-dev/dr-seed) OU cole o conteúdo.
#     3. bash dr-restore.sh              → lista os backups (não muda nada)
#        bash dr-restore.sh restaurar    → restaura TUDO no lugar (servidor novo)
#        bash dr-restore.sh testar /tmp/dr  → restaura numa pasta, pra ensaiar
#
#  SEGREDOS QUE VOCÊ VAI PRECISAR (do iCloud, nota "SEGREDOS DE RECUPERAÇÃO"):
#     1) RESTIC_PASSWORD  — descriptografa o backup
#     2) Senha da subconta Storage Box u622685-sub3 — acessa o repositório
# =============================================================================
set -euo pipefail

# --- Coordenadas do backup (NÃO são segredo — podem ficar no script/GitHub) ---
SB_USER="u622685-sub3"
SB_HOST="u622685.your-storagebox.de"
SB_PORT="23"
RESTIC_REPOSITORY="sftp:${SB_USER}@${SB_HOST}:"
export RESTIC_REPOSITORY

MODO="${1:-listar}"
ALVO="${2:-/}"

msg(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
erro(){ printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# Limpa os segredos da memória ao sair, aconteça o que acontecer.
limpar(){ unset RESTIC_PASSWORD SSHPASS 2>/dev/null || true; }
trap limpar EXIT

# --- 1. Dependências (restic + sshpass) num servidor cru --------------------
msg "Verificando dependências"
if ! command -v restic >/dev/null 2>&1; then
  echo "  instalando restic…"; apt-get update -qq && apt-get install -y -qq restic || erro "não instalei o restic"
fi
if ! command -v sshpass >/dev/null 2>&1; then
  echo "  instalando sshpass…"; apt-get install -y -qq sshpass || erro "não instalei o sshpass"
fi
if ! command -v python3 >/dev/null 2>&1; then
  apt-get install -y -qq python3 || erro "não instalei o seletor de snapshots"
fi
echo "  restic $(restic version 2>/dev/null | awk '{print $2}') · sshpass ok"

# --- 2. Senhas (do iCloud) — digitadas, nunca gravadas ----------------------
msg "Senhas de recuperação (do app Senhas do iCloud)"
read -rsp "  1) RESTIC_PASSWORD: " RESTIC_PASSWORD; echo
[ -n "$RESTIC_PASSWORD" ] || erro "senha do restic vazia"
read -rsp "  2) Senha da subconta Storage Box (${SB_USER}): " SSHPASS; echo
[ -n "$SSHPASS" ] || erro "senha do Storage Box vazia"
export RESTIC_PASSWORD SSHPASS

# sshpass -e lê a senha da variável SSHPASS (NÃO do argv → não aparece no 'ps')
SFTP_CMD="sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no -p ${SB_PORT} ${SB_USER}@${SB_HOST} -s sftp"
restic_(){ restic -o sftp.command="$SFTP_CMD" "$@"; }

# --- 3. Conferência: as senhas abrem o backup? (falha cedo) -----------------
msg "Conectando no backup"
if ! SNAPSHOTS=$(restic_ snapshots --json); then
  erro "não abri o repositório. Senha do restic ERRADA, senha do Storage Box ERRADA, ou sem internet."
fi
echo "  ✅ conectado e descriptografado"
SELECTOR="$(dirname "$(readlink -f "$0")")/select-snapshot.py"
ULT_ID=$(printf '%s' "$SNAPSHOTS" | python3 "$SELECTOR") || erro "nenhum backup completo disponível; não vou usar latest sem filtro"
ULT_TS=$(printf '%s' "$SNAPSHOTS" | python3 "$SELECTOR" --time) || erro "data do backup inválida"
echo "  backup mais novo: ${ULT_ID:-?}  (${ULT_TS:-?})"

case "$MODO" in
  listar)
    msg "Backups disponíveis (nada foi alterado)"
    restic_ snapshots 2>/dev/null | tail -15
    cat <<EOF

  Para restaurar de verdade (servidor NOVO):   bash $0 restaurar
  Para ensaiar numa pasta sem tocar no sistema: bash $0 testar /tmp/dr
EOF
    ;;

  testar)
    msg "ENSAIO — restaurando o snapshot mais novo em: $ALVO"
    mkdir -p "$ALVO"
    restic_ restore "$ULT_ID" --target "$ALVO"
    echo "  ✅ restaurado em $ALVO (sistema real intacto). Confira e apague quando quiser."
    ;;

  restaurar)
    msg "RESTAURAÇÃO REAL no lugar (alvo: $ALVO)"
    echo "  ⚠️  Use isto só num servidor NOVO/cru. Vai sobrescrever arquivos existentes."
    read -rp "  Digite RESTAURAR para confirmar: " C
    [ "$C" = "RESTAURAR" ] || erro "cancelado"
    restic_ restore "$ULT_ID" --target "$ALVO"
    msg "Arquivos restaurados"
    cat <<'EOF'
  PRÓXIMOS PASSOS (reconstrução assistida; não automatizada pelo Ankh):
   • Os arquivos voltaram: /opt/*, /etc/*, /root/*, /home/*
   • Os dumps de banco estão em /opt/horus-backup/staging/*.sql (reimportar com serviço parado)
   • Recrie os serviços a partir do inventário e reimporte os bancos antes de publicar.
   • O banco Aton consistente está em staging/aton-live.sqlite; veja dr-sqlite.json.
EOF
    ;;

  *) erro "modo inválido '$MODO' — use: listar | testar <dir> | restaurar" ;;
esac
