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

# 2. rode
bash dr-restore.sh                 # lista os backups (não altera nada)
bash dr-restore.sh testar /tmp/dr  # ENSAIO: restaura numa pasta, sistema intacto
bash dr-restore.sh restaurar       # REAL: restaura tudo no lugar (servidor novo)
```

## O que ele faz (Camada 0) e o que NÃO faz

**Faz:** instala `restic` + `sshpass`, conecta no backup com as suas senhas,
restaura os arquivos (`/opt/*`, `/etc/*`, `/root/*`, `/home/*`).

**Não faz** (isso é a Camada 1 — o Ankh em modo-recuperação):
reimportar os bancos (`.sql` em `/opt/horus-backup/staging/`), instalar pacotes do
sistema, recriar serviços systemd, subir Docker/pm2, DNS/certbot. O seed deixa o
`/opt/ankh` restaurado e pronto para assumir daqui.

## Segurança

- As senhas são digitadas (nunca exibidas, `read -s`) e **nunca gravadas em disco**.
- A senha do Storage Box vai por `sshpass -e` (variável de ambiente) — **não** aparece
  na lista de processos (`ps`).
- Coordenadas do backup (host, usuário, porta) **não são segredo** e ficam no script.
- Testado em 24/jul/2026: conexão, descriptografia e restore reais confirmados.
