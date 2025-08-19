#!/usr/bin/env bash
set -euo pipefail

# deploy-ubuntu.sh
# Script para executar na sua instância Ubuntu EC2 (usuário ubuntu) para:
# - criar swap de 2GB (se não existir)
# - garantir docker + docker compose
# - gerar .env interativamente a partir de .env.example (API key + Caddy hash)
# - puxar imagens e subir a stack
#
# Uso:
# scp o repositório/arquivo para a instância ou clone o repo nela
# ssh -i "evolution-api.pem" ubuntu@ec2-... 
# cd /path/to/project
# sudo bash ./deploy-ubuntu.sh

PROJECT_DIR="$(pwd)"
EXAMPLE_FILE="$PROJECT_DIR/.env.example"
ENV_FILE="$PROJECT_DIR/.env"

if [[ ! -f "$EXAMPLE_FILE" ]]; then
  echo ".env.example não encontrado no diretório atual: $PROJECT_DIR"
  exit 1
fi

echo "==> Iniciando deploy na instância (diretório: $PROJECT_DIR)"

### 1) Swap 2GB
if swapon --show | grep -q '^'; then
  echo "Swap já configurado. Pulando criação do swap."
else
  echo "Criando swap de 2G em /swapfile ..."
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  echo "Swap criado e ativado."
fi

### 2) Docker & Docker Compose
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker não encontrado. Instalando Docker..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  echo "Docker instalado. Você pode precisar relogar para usar docker sem sudo."
else
  echo "Docker encontrado: $(docker --version)"
fi

# docker compose v2 usa o comando `docker compose`. Verifica
if docker compose version >/dev/null 2>&1; then
  echo "docker compose disponível: $(docker compose version 2>/dev/null | head -n1)"
else
  echo "docker compose não disponível. Tentando instalar plugin docker-compose..."
  sudo apt-get update
  sudo apt-get install -y docker-compose-plugin || true
fi

### 3) Gerar .env a partir de .env.example (interativo)
echo
echo "==== Gerar arquivo .env a partir de .env.example ===="

read -p "Digite o domínio completo (ex: api.seu-dominio.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then echo "Domínio é obrigatório."; exit 1; fi

read -p "Digite o e-mail para ACME/Let's Encrypt: " ACME_EMAIL
if [[ -z "$ACME_EMAIL" ]]; then echo "ACME email é obrigatório."; exit 1; fi

while true; do
  read -s -p "Digite a senha do Postgres (evite usar @): " POSTGRES_PASSWORD
  echo
  read -s -p "Confirme a senha do Postgres: " POSTGRES_PASSWORD2
  echo
  [[ "$POSTGRES_PASSWORD" == "$POSTGRES_PASSWORD2" && -n "$POSTGRES_PASSWORD" ]] && break
  echo "Senhas não conferem ou estão vazias. Tente novamente." >&2
done

while true; do
  read -s -p "Digite a senha do Manager (Basic Auth): " MANAGER_PASS
  echo
  read -s -p "Confirme a senha do Manager: " MANAGER_PASS2
  echo
  [[ "$MANAGER_PASS" == "$MANAGER_PASS2" && -n "$MANAGER_PASS" ]] && break
  echo "Senhas não conferem ou estão vazias. Tente novamente." >&2
done

echo "Gerando AUTHENTICATION_API_KEY (64 hex chars)..."
AUTH_KEY=$(openssl rand -hex 32)

echo "Tentando gerar hash do Caddy via docker..."
CADDY_HASH=""
if command -v docker >/dev/null 2>&1; then
  set +e
  CADDY_HASH=$(docker run --rm caddy caddy hash-password --plaintext "$MANAGER_PASS" 2>/dev/null || true)
  set -e
  if [[ -z "$CADDY_HASH" ]]; then
    echo "Falha ao gerar hash via docker. Você poderá gerar localmente e colar o hash." >&2
    read -p "Cole aqui o hash do Caddy (ou pressione Enter para abortar): " CADDY_HASH
    if [[ -z "$CADDY_HASH" ]]; then echo "Hash do Caddy necessário."; exit 1; fi
  fi
else
  echo "Docker não disponível para gerar hash; gere o hash localmente com: docker run --rm caddy caddy hash-password --plaintext 'SUA_SENHA'"
  read -p "Cole aqui o hash do Caddy (obrigatório): " CADDY_HASH
  if [[ -z "$CADDY_HASH" ]]; then echo "Hash do Caddy necessário."; exit 1; fi
fi

# Escapa '@' na senha para a connection URI
DB_PASS_ESCAPED=${POSTGRES_PASSWORD//@/%40}
DB_URI="postgresql://evolution:${DB_PASS_ESCAPED}@postgres:5432/evolution"

cat > "$ENV_FILE" <<EOF
# ===== AUTH DA EVOLUTION =====
AUTHENTICATION_API_KEY=${AUTH_KEY}

# ===== POSTGRES =====
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=evolution
POSTGRES_USER=evolution
DATABASE_ENABLED=true
DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=${DB_URI}

# ===== CACHE (sem Redis no Free Tier) =====
CACHE_REDIS_ENABLED=false
CACHE_LOCAL_ENABLED=true

# ===== LOG =====
LOG_LEVEL=info

# ===== DOMÍNIO / SSL =====
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

# ===== BASIC AUTH no /manager (Caddy) =====
BASIC_AUTH_USER=admin
BASIC_AUTH_HASH=${CADDY_HASH}
EOF

chmod 600 "$ENV_FILE" || true
echo ".env criado em: $ENV_FILE"

### 4) Pull e up da stack
echo "Puxando imagens e iniciando a stack (pode levar alguns minutos)..."
docker compose pull || true
docker compose up -d

echo "Deploy finalizado. Verifique logs:"
echo "  docker logs -f evolution_caddy"
echo "  docker logs -f evolution_api"

echo "Aguarde Caddy emitir o certificado e então acesse: https://$DOMAIN"

exit 0
