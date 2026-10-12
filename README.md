# dr-seed — Semente de Recuperação de Desastre

O script **mínimo** para ressuscitar a plataforma (idee.haus / Horus) num servidor
Ubuntu **novo e cru**, na Netcup ou em qualquer lugar.

## Por que existe

Se o servidor morrer, o backup (restic → Storage Box da Hetzner) continua vivo, mas
para **abri-lo** você precisa de duas coisas que ficam **fora** do servidor:

1. `RESTIC_PASSWORD` — descriptografa o backup
2. Senha da subconta Storage Box `u622685-sub3` — acessa o repositório

As duas estão na sua nota do **app Senhas do iCloud** ("SEGREDOS DE RECUPERAÇÃO DE
DESASTRE"). Este script pega essas senhas de você na hora e restaura tudo. **Ele
nunca contém segredo** — pode ser público sem risco (mas mantemos privado).

## Uso

Num servidor novo, como root:

```bash
# 1. baixe este script (ou cole o conteúdo)
curl -sSLO https://raw.githubusercontent.com/alpfreitas-dev/dr-seed/master/dr-restore.sh
curl -sSLO https://raw.githubusercontent.com/alpfreitas-dev/dr-seed/master/select-snapshot.py

# 2. rode
bash dr-restore.sh                 # lista os backups (não altera nada)
bash dr-restore.sh testar /tmp/dr  # ENSAIO: restaura numa pasta, sistema intacto
bash dr-restore.sh restaurar       # REAL: restaura tudo no lugar (servidor novo)
```

## O que ele faz (Camada 0) e o que NÃO faz

**Faz:** instala `restic` + `sshpass`, conecta no backup com as suas senhas,
restaura os arquivos (`/opt/*`, `/etc/*`, `/root/*`, `/home/*`).

**Não faz** (isso é a Camada 1 — `recover.sh`):
reimportar os bancos, instalar pacotes do sistema, recriar serviços systemd, subir
Docker/pm2, DNS/certbot.

## Camada 1 — `recover.sh` (depois que os arquivos voltaram)

**Atenção (12/out/2026):** o fluxo completo de reconstrução ainda precisa de revisão
e ensaio. Não execute `all` automaticamente: o manifesto histórico não contempla
todos os projetos atuais. Use os inventários `staging/dr-*` e os dumps SQL/SQLite.
O Ankh não tem um modo de recuperação automática implementado.

O seletor exige um snapshot completo e rejeita os snapshots de sessões Codex e os
marcados `backup-incomplete`. Os bancos SQLite consistentes ficam no staging;
`dr-sqlite.json` identifica os destinos originais. Reponha-os apenas com seus
respectivos serviços parados e sem WAL/SHM antigos. O teste de restauração foi
adiado por solicitação do André; seleção e cópia SQLite têm testes sintéticos.

```bash
bash recover.sh check       # relatório: o que existe/falta (não muda nada) — seguro sempre
bash recover.sh provision   # repos + pacotes (docker, node, certbot, pm2…)
bash recover.sh dbrestore   # reimporta os dumps .sql nos bancos vazios
bash recover.sh services    # daemon-reload + systemd + docker compose + pm2 + nginx
bash recover.sh all         # tudo, com confirmação
```

Manifesto declarativo no topo do script (pacotes, serviços, dirs) — mantenha-o
quando um serviço novo entrar na plataforma. Cada passo verifica seu resultado.
`check` é só-leitura; os demais são destrutivos → só num servidor NOVO/cru.
Depois: apontar o DNS pro IP novo e `certbot --nginx` se os certs não vieram do backup.

## Ensaio (validar a recuperação num servidor descartável)

⚠️ O descartável vai segurar **a joia da coroa**: bancos com dados de cliente, todos os
segredos e credenciais REAIS (WhatsApp Cloud API, Meta CAPI, Google Ads, Shopify, Guru,
push, SMTP). Dois cuidados obrigatórios — cada um tem seu script:

**1. Lacrar a rede antes de subir os apps** (`seal-network.sh`)

Se os apps subirem com saída livre e processarem a fila do banco, mandam mensagem pra
cliente de verdade, disparam push real e poluem os dados de anúncio da produção.
(Webhooks de *entrada* não são risco: batem no domínio de prod, IP diferente.)

```bash
touch /root/.dr-drill          # marca este servidor como o do ensaio (as travas exigem)
bash seal-network.sh open      # saída liberada — para instalar pacotes
bash recover.sh provision
bash seal-network.sh seal      # LACRA: só Storage Box + DNS + SSH
bash seal-network.sh status    # confirma que NÃO alcança a Meta
bash dr-restore.sh restaurar
bash recover.sh dbrestore
bash recover.sh services       # apps sobem lacrados: não alcançam ninguém
```

**2. Destruir com cuidado no fim** (`teardown.sh`)

Deletar a VM desaloca o disco, mas nem sempre o zera. Sobrescreva antes:

```bash
bash teardown.sh check   # lista o que será destruído (não apaga)
bash teardown.sh wipe    # shred nos segredos, drop nos bancos, limpa histórico,
                         # zera o espaço livre — pede DESTRUIR pra confirmar
```
Depois: **delete a VM no painel** e confirme.

**Travas:** os dois scripts se recusam a rodar sem `/root/.dr-drill`, e o `seal-network.sh`
detecta se está no servidor de produção e aborta. Testado.

**Dimensionamento:** o ensaio cabe em ~16 GB de disco. Com 4 GB de RAM, valide
`provision` + `dr-restore` + `dbrestore` (a parte que importa) e suba os serviços
**um de cada vez** — todos juntos não cabem.

## Segurança

- As senhas são digitadas (nunca exibidas, `read -s`) e **nunca gravadas em disco**.
- A senha do Storage Box vai por `sshpass -e` (variável de ambiente) — **não** aparece
  na lista de processos (`ps`).
- Coordenadas do backup (host, usuário, porta) **não são segredo** e ficam no script.
- Testado em 24/jul/2026: conexão, descriptografia e restore reais confirmados.
