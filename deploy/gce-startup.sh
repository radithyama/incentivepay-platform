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
ENV_FILE="$APP_DIR/incentivepay-platform/.env.prod"
if [ ! -f "$ENV_FILE" ]; then
  PUBLIC_HOST=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/public-host")
  HMAC_SECRET=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/hmac-secret")
  KC_ADMIN_PASSWORD=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/kc-admin-password")
  APP_SCHEME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-scheme")

  cat > "$ENV_FILE" <<ENVEOF
PUBLIC_HOST=${PUBLIC_HOST}
KEYCLOAK_PUBLIC_PORT=8081
VITE_API_BASE_URL=${APP_SCHEME}://${PUBLIC_HOST}:8080
VITE_LEDGER_BASE_URL=${APP_SCHEME}://${PUBLIC_HOST}:8082
VITE_KEYCLOAK_URL=${APP_SCHEME}://${PUBLIC_HOST}:8081
HMAC_SECRET=${HMAC_SECRET}
KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
ENVEOF
fi

cd "$APP_DIR/incentivepay-platform"
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build
