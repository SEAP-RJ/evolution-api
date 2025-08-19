# evolution-api

Pequeno guia "pronto pra produção leve" (AWS Free Tier) para a stack:

- PostgreSQL (oficial)
- Evolution API (container)
- Caddy (proxy HTTPS automático + Basic Auth /manager)

Arquivos importantes

- `docker-compose.yml` — define os serviços (postgres, evolution-api, caddy)
- `Caddyfile` — configuração do Caddy com headers, basic auth e proxy
- `.env.example` — template seguro (não commite `.env` real)
- `generate-env.ps1` — gera `.env` localmente (PowerShell)
- `deploy-ubuntu.sh` — script de deploy para instâncias Ubuntu/EC2 (swap, Docker, gerar .env e subir stack)
- `.github/COPILOT_INSTRUCTIONS.md` — orientação interna para o GitHub Copilot sobre padrões e convenções do repositório

Resumo rápido de passos

1. Suba uma EC2 (t3.micro / free tier) com Ubuntu.
2. Aponte DNS (A record) do seu domínio/subdomínio para o IP público da EC2.
3. Configure o Security Group: abra 80 e 443 para o mundo; feche 8080.
4. Clone/reposicione este repositório na EC2.
5. Rode `sudo bash ./deploy-ubuntu.sh` (ou use `generate-env.ps1` no Windows para gerar `.env`).
6. Aguarde o Caddy emitir o certificado e acesse `https://SEU_DOMINIO`.

Detalhes importantes

DNS

- Crie um registro A para `api.seu-dominio.com` apontando para o IP público da EC2.
- TTL baixo durante testes (ex: 60s) facilita propagação.

Security Group (exemplo mínimo)

- Inbound:
  - TCP 80 (0.0.0.0/0)
  - TCP 443 (0.0.0.0/0)
  - TCP 22 (apenas seu IP ou rede de administração)
- Não abrir 8080 publicamente — Caddy faz o proxy internamente.

Swap (por que e como)

- AMIs t3.micro têm 1GB de RAM; Chromium/headless pode exigir mais memória.
- Criar swap ajuda a evitar OOM fatal quando o Chromium é usado.
- Comandos (já presentes no `deploy-ubuntu.sh`):

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

Gerando `.env` com segurança

- Não commite `.env` com segredos. Use `.env.example` como template.
- No Windows/PowerShell local: rode `.uild\generate-env.ps1` (ou `.
elative_path\generate-env.ps1`) para prompts seguros. O script gera uma API key forte e tenta gerar o hash do Caddy via Docker.
- Na EC2 Ubuntu: rode `sudo bash ./deploy-ubuntu.sh` e siga os prompts interativos.

Criar hash do Basic Auth (opcional local)

- Se preferir gerar o hash manualmente (local):

```powershell
docker run --rm caddy caddy hash-password --plaintext 'SUA_SENHA'
```

Backups e restauração

Banco (pg_dump)

- Fazer backup rápido (executar em host com `psql` ou dentro do contêiner):

```bash
# executar dentro do contêiner postgres
docker exec -it evolution_postgres pg_dump -U evolution -d evolution > backup_evolution.sql

# ou usando psql remoto (se configurado)
PGPASSWORD=SuaSenha pg_dump -h postgres_host -U evolution evolution > backup_evolution.sql
```

Restaurar

```bash
# restaurar para um banco vazio
cat backup_evolution.sql | docker exec -i evolution_postgres psql -U evolution -d evolution
```

Volumes a preservar

- `pgdata` — dados do Postgres
- `evolution_instances` — instâncias/arquivos gerados pela Evolution API

Operação e manutenção

- Atualizar a imagem da API: `docker compose pull evolution-api && docker compose up -d`
- Logs: `docker logs -f evolution_caddy` e `docker logs -f evolution_api`
- Evite usar `:latest` em produção — prefira tags imutáveis ou digests para reprodutibilidade.

Segurança / boas práticas rápidas

- Remova `.env` com valores sensíveis do repositório e use `.env.example` no git.
- Use uma chave forte em `AUTHENTICATION_API_KEY` e troque periodicamente.
- Restrinja SSH no Security Group a IPs confiáveis.

Ajuda adicional

- Quer que eu adicione um `systemd` unit para subir a stack no boot, ou um job de backup automático (cron) para `pg_dump` e upload para S3? Diga "systemd" ou "backup" e eu adiciono.

Instruções para GitHub Copilot

- Este repositório contém um arquivo de instruções para o GitHub Copilot em `.github/COPILOT_INSTRUCTIONS.md`.
- O arquivo orienta convenções de formatação, segurança (não comitar `.env`), e padrões ao gerar código/snippets.
- Mantenha o arquivo atualizado quando alterar padrões de contribuição ou regras de geração automática.

---

FIM
