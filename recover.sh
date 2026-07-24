#!/usr/bin/env bash
# =============================================================================
#  recover.sh — CAMADA 1 da recuperação de desastre (provisiona + sobe tudo)
#  idee.haus / Horus — plataforma Netcup
# =============================================================================
#  Roda DEPOIS do dr-restore.sh (Camada 0), que já restaurou os arquivos.
#  Este script deixa o servidor novo funcionando: instala os pacotes, reimporta
#  os bancos e sobe os serviços. Cada passo VERIFICA seu resultado.
#
#  Manifesto declarativo abaixo — para não apodrecer, mantenha-o quando um
#  serviço/pacote novo entrar na plataforma.
#
#  USO:
#     bash recover.sh check        → só relatório: o que existe/falta (não muda nada)
#     bash recover.sh provision    → instala repos+pacotes (docker, node, certbot…)
#     bash recover.sh dbrestore    → reimporta os dumps .sql (bancos VAZIOS!)
#     bash recover.sh services     → daemon-reload + systemd + docker + pm2
#     bash recover.sh all          → provision → dbrestore → services (confirma)
#
#  ⚠️ dbrestore/services/all SÃO destrutivos — rode só num servidor NOVO/cru.
# =============================================================================
set -uo pipefail

# ── Manifesto ────────────────────────────────────────────────────────────────
APT_UBUNTU=(nginx restic sshpass zip python3 python3-pip jq curl gnupg ca-certificates)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
NPM_GLOBAL=(pm2)
COMPOSE_DIRS=(/opt/alphavip /opt/studio)                 # docker compose up -d
PM2_APPS=(horus horus-saas)                              # sobem como usuário ubuntu
SYSTEMD_UNITS=(thoth ankh thoth-mcp studio-webp.path studio-webp.timer \
               ankh-collector-fast.timer ankh-collector-slow.timer ankh-collector-procs.timer)
STAGE=/opt/horus-backup/staging                         # dumps .sql do backup

MODO="${1:-check}"
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[1;31m✗\033[0m %s\n' "$1"; }
inf(){ printf '  · %s\n' "$1"; }
sec(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ── check (só leitura — seguro em QUALQUER lugar) ────────────────────────────
do_check(){
  sec "Pacotes"
  for c in docker nginx node restic sshpass certbot pm2 python3 jq; do
    have "$c" && ok "$c ($(command -v $c))" || no "$c FALTA"
  done
  sec "Repositórios apt (recriáveis pelo provision)"
  for r in docker nodesource crowdsec; do
    ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi "$r" && ok "$r" || no "$r ausente"
  done
  sec "Serviços systemd"
  for u in "${SYSTEMD_UNITS[@]}"; do
    # units sem sufixo (thoth, ankh, thoth-mcp) são .service; .path/.timer já vêm completos
    case "$u" in *.*) unit="$u";; *) unit="$u.service";; esac
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q . && ok "$u presente" || no "$u ausente (restaure /etc/systemd/system)"
  done
  sec "Docker compose"
  for d in "${COMPOSE_DIRS[@]}"; do
    [ -f "$d/docker-compose.yml" ] && ok "$d" || no "$d sem compose (restaure primeiro)"
  done
  sec "Dumps de banco para reimportar"
  if [ -d "$STAGE" ]; then
    ls "$STAGE"/*.sql 2>/dev/null | while read f; do inf "$(basename "$f") ($(du -h "$f" | cut -f1))"; done
    [ -z "$(ls "$STAGE"/*.sql 2>/dev/null)" ] && no "nenhum .sql em $STAGE"
  else no "$STAGE não existe (restaure o backup primeiro)"; fi
  sec "pm2 (usuário ubuntu)"
  sudo -u ubuntu pm2 jlist >/dev/null 2>&1 && ok "pm2 responde" || inf "pm2 ainda não iniciado (normal antes do 'services')"
}

# ── provision (instala) ──────────────────────────────────────────────────────
do_provision(){
  [ "$(id -u)" = 0 ] || { no "provision precisa de root"; return 1; }
  sec "Repositórios + chaves"
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && ok "chave Docker" || no "chave Docker"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  fi
  if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && ok "chave NodeSource" || no "chave NodeSource"
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.sources 2>/dev/null || \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  fi
  sec "apt update + pacotes"
  apt-get update -qq || no "apt update falhou"
  apt-get install -y -qq "${APT_UBUNTU[@]}" && ok "pacotes Ubuntu" || no "pacotes Ubuntu"
  apt-get install -y -qq nodejs && ok "node $(node --version)" || no "node"
  apt-get install -y -qq "${DOCKER_PKGS[@]}" && ok "docker $(docker --version 2>/dev/null|awk '{print $3}'|tr -d ,)" || no "docker"
  sec "certbot (snap) + pm2 (npm)"
  have snap && { snap install --classic certbot 2>/dev/null && ln -sf /snap/bin/certbot /usr/bin/certbot && ok "certbot"; } || no "snap ausente (certbot manual)"
  npm install -g "${NPM_GLOBAL[@]}" >/dev/null 2>&1 && ok "pm2 $(sudo -u ubuntu pm2 --version 2>/dev/null)" || no "pm2"
  inf "CrowdSec: repo packagecloud — instale à parte se quiser as defesas (não bloqueia o resto)"
}

# ── dbrestore (reimporta os .sql em bancos VAZIOS) ───────────────────────────
do_dbrestore(){
  [ "$(id -u)" = 0 ] || { no "dbrestore precisa de root"; return 1; }
  sec "Subindo containers de banco (vazios) antes de importar"
  for d in "${COMPOSE_DIRS[@]}"; do (cd "$d" && docker compose up -d 2>/dev/null) && ok "compose up: $d"; done
  sleep 8   # dá tempo do Postgres/MySQL aceitarem conexão
  sec "Postgres (studio-db, alphavip-db)"
  for f in "$STAGE"/pg-*.sql; do
    [ -f "$f" ] || continue
    c=$(basename "$f" .sql | sed 's/^pg-//')
    if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
      docker exec -i "$c" psql -U postgres < "$f" >/dev/null 2>&1 && ok "importado: $c" || no "falha import $c"
    else no "container $c não está no ar"; fi
  done
  sec "MySQL (saas em docker, horus nativo)"
  [ -f "$STAGE/mysql-saas.sql" ] && docker ps --format '{{.Names}}' | grep -q horus-saas-mysql && \
    docker exec -i horus-saas-mysql sh -c 'mysql -uroot' < "$STAGE/mysql-saas.sql" 2>/dev/null && ok "saas" || inf "saas: ajustar credencial root do container"
  [ -f "$STAGE/mysql-horus.sql" ] && have mysql && mysql < "$STAGE/mysql-horus.sql" 2>/dev/null && ok "horus" || inf "horus: MySQL nativo precisa estar instalado+rodando"
  inf "⚠️ Credenciais dos bancos: confira os usuários/senhas dos .env — o dump traz dados, não os GRANTs de app"
}

# ── services (sobe tudo) ──────────────────────────────────────────────────────
do_services(){
  [ "$(id -u)" = 0 ] || { no "services precisa de root"; return 1; }
  sec "systemd"
  systemctl daemon-reload && ok "daemon-reload"
  for u in "${SYSTEMD_UNITS[@]}"; do
    systemctl enable --now "$u" >/dev/null 2>&1 && ok "$u" || no "$u (ver journalctl -u $u)"
  done
  sec "docker compose (rebuild + up)"
  for d in "${COMPOSE_DIRS[@]}"; do (cd "$d" && docker compose up -d --build 2>/dev/null) && ok "$d" || no "$d"; done
  sec "pm2 (usuário ubuntu)"
  for a in "${PM2_APPS[@]}"; do
    d="/home/ubuntu/$a"
    [ -f "$d/dist/index.js" ] && sudo -u ubuntu bash -c "cd $d && pm2 start dist/index.js --name $a" >/dev/null 2>&1 && ok "$a" || no "$a (build ausente? npm ci && npm run build)"
  done
  sudo -u ubuntu pm2 save >/dev/null 2>&1 && ok "pm2 save"
  sec "nginx"
  nginx -t 2>/dev/null && systemctl reload nginx && ok "nginx recarregado" || no "nginx -t falhou — revise a config"
  inf "Falta você: apontar o DNS pro IP novo e rodar 'certbot --nginx' se os certs não vieram do backup"
}

case "$MODO" in
  check)     do_check ;;
  provision) do_provision ;;
  dbrestore) do_dbrestore ;;
  services)  do_services ;;
  all)
    echo "⚠️  Isto instala, REIMPORTA bancos e sobe serviços. Só num servidor NOVO."
    read -rp "Digite RECUPERAR para confirmar: " C; [ "$C" = "RECUPERAR" ] || { echo "cancelado"; exit 1; }
    do_provision && do_dbrestore && do_services
    sec "Pronto — rode 'bash recover.sh check' para conferir o estado" ;;
  *) echo "uso: bash recover.sh {check|provision|dbrestore|services|all}"; exit 1 ;;
esac
