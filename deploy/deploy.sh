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
  # Shared config changed - bring the whole stack in line with it.
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build
  # Compose only recreates a container when it detects the resolved service
  # config (image, env, the volume *list*) changed - it has no way to know
  # that a bind-mounted file's *contents* changed on disk, since from
  # Compose's point of view the mount itself is identical. caddy and
  # keycloak are both configured almost entirely through bind-mounted files
  # (Caddyfile; the login theme and, on a fresh volume, realm-export.json),
  # so an `up -d` after a config-only edit silently leaves them running the
  # OLD file - confirmed live: a Caddyfile change sat inert for 19+ hours
  # across several deploys until an explicit --force-recreate. Both are
  # cheap/safe to force-recreate every "platform" deploy (Caddy: brief
  # connection blip, no cert reissuance; Keycloak: existing sessions/data
  # persist in Postgres, this is not the fresh-import path).
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --force-recreate caddy keycloak
else
  docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d --build "$SERVICE"
fi
