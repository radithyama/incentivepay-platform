#!/bin/bash
# Invoked by the restricted `deploy` user via sudo (see deploy/README or the
# platform README's "CD pipeline" section for the sudoers rule that makes
# this the ONLY thing that account can run as root). One argument: which
# service changed, matching a docker-compose service name, or "platform" for
# changes to shared config (docker-compose.yml, Caddyfile, realm-export.json).
set -euo pipefail

SERVICE="${1:?usage: deploy.sh <incentive-api|ledger-service|notification-service|frontend|platform>}"
APP_DIR=/opt/incentivepay
PLATFORM_DIR="$APP_DIR/incentivepay-platform"

case "$SERVICE" in
  incentive-api) REPO=incentivepay-incentive-api ;;
  ledger-service) REPO=incentivepay-ledger-service ;;
  notification-service) REPO=incentivepay-notification-service ;;
  frontend) REPO=incentivepay-frontend ;;
  platform) REPO=incentivepay-platform ;;
  *) echo "Unknown service: $SERVICE" >&2; exit 1 ;;
esac

git -C "$APP_DIR/$REPO" pull --ff-only

cd "$PLATFORM_DIR"
if [ "$SERVICE" = "platform" ]; then
  # Shared config changed - bring the whole stack in line with it. Compose
  # only recreates containers whose actual config changed, so this is safe
  # to run even when only one service's image needs rebuilding.
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build
else
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build "$SERVICE"
fi
