#!/bin/bash
# GCE startup script - runs on every boot (idempotent). Provisions Docker,
# clones the 5 IncentivePay repos as siblings, and brings up the stack via
# the production compose overlay. See ../docker-compose.prod.yml and
# ../.env.prod.example.
set -euo pipefail

APP_DIR=/opt/incentivepay
REPO_BASE="https://github.com/radithyama"
REPOS=(incentivepay-platform incentivepay-incentive-api incentivepay-ledger-service incentivepay-notification-service incentivepay-frontend)

# --- Docker ---
if ! command -v docker &>/dev/null; then
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# --- Swap (e2-medium is only 4GB RAM; this stack is memory-hungry) ---
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Clone/update repos ---
mkdir -p "$APP_DIR"
for repo in "${REPOS[@]}"; do
  if [ -d "$APP_DIR/$repo/.git" ]; then
    git -C "$APP_DIR/$repo" pull --ff-only
  else
    git clone "$REPO_BASE/$repo.git" "$APP_DIR/$repo"
  fi
done

# --- .env.prod: written once from instance metadata, never committed ---
# Metadata keys expected (see deploy note in the platform README): hmac-secret,
# kc-admin-password, keycloak-public-host, vite-api-base-url,
# vite-ledger-base-url, vite-keycloak-url, cors-allowed-origins,
# keycloak-admin-client-secret. All required - this fails loudly (curl
# returns 404 body, which becomes a broken .env.prod) rather than silently
# deploying with blank/wrong URLs baked into the frontend bundle or a CORS
# config that blocks the frontend from reaching the API.
ENV_FILE="$APP_DIR/incentivepay-platform/.env.prod"
if [ ! -f "$ENV_FILE" ]; then
  md() { curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

  cat > "$ENV_FILE" <<ENVEOF
HMAC_SECRET=$(md hmac-secret)
KEYCLOAK_ADMIN_PASSWORD=$(md kc-admin-password)
KEYCLOAK_PUBLIC_HOST=$(md keycloak-public-host)
VITE_API_BASE_URL=$(md vite-api-base-url)
VITE_LEDGER_BASE_URL=$(md vite-ledger-base-url)
VITE_KEYCLOAK_URL=$(md vite-keycloak-url)
CORS_ALLOWED_ORIGINS=$(md cors-allowed-origins)
KEYCLOAK_ADMIN_CLIENT_SECRET=$(md keycloak-admin-client-secret)
ENVEOF
fi

cd "$APP_DIR/incentivepay-platform"
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build
