#!/usr/bin/env bash
# One-time bootstrap for the Cloudflare Tunnel + Traefik stack (Ubuntu server).
# Run from the repo root. Requires: docker + docker compose, and cloudflared.
set -euo pipefail

cd "$(dirname "$0")"

TUNNEL_NAME="${1:-homelab}"

echo "==> 1/6  Checking prerequisites"
command -v docker >/dev/null || { echo "docker not found — see README 'Prerequisites (Ubuntu)'"; exit 1; }
if ! command -v cloudflared >/dev/null; then
  cat <<'EOF'
cloudflared not found. Install it on Ubuntu:

  sudo mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list
  sudo apt-get update && sudo apt-get install -y cloudflared

EOF
  exit 1
fi

echo "==> 2/6  Cloudflare login (prints a URL — open it in any browser, pick your zone)"
# Writes ~/.cloudflared/cert.pem — the account credential used to create tunnels.
cloudflared tunnel login

echo "==> 3/6  Creating tunnel '$TUNNEL_NAME'"
cloudflared tunnel create "$TUNNEL_NAME"

# Grab the tunnel UUID and copy its credentials file into ./cloudflared
TUNNEL_ID="$(cloudflared tunnel list --output json | python3 -c \
  "import sys,json;print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL_NAME'))")"
echo "    Tunnel ID: $TUNNEL_ID"
cp "$HOME/.cloudflared/$TUNNEL_ID.json" "./cloudflared/$TUNNEL_ID.json"

echo "==> 4/6  Wiring config.yml with the tunnel ID"
sed -i.bak "s/CHANGE_ME_TUNNEL_ID/$TUNNEL_ID/g" cloudflared/config.yml && rm -f cloudflared/config.yml.bak

echo "==> 5/6  Creating wildcard DNS route (*.<domain> -> this tunnel)"
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
  cloudflared tunnel route dns "$TUNNEL_NAME" "*.$DOMAIN" || \
    echo "    (wildcard route may already exist, or add a *.$DOMAIN CNAME to $TUNNEL_ID.cfargotunnel.com in the dashboard)"
else
  echo "    Skipped: create .env (from .env.example) with DOMAIN=... first, then run:"
  echo "    cloudflared tunnel route dns $TUNNEL_NAME '*.<your-domain>'"
fi

echo "==> 6/6  Creating the shared docker network and starting the stack"
docker network inspect edge >/dev/null 2>&1 || docker network create edge
docker compose up -d

echo
echo "Done. Bring up an app:   cd apps/whoami && docker compose up -d"
echo "Then visit:              https://whoami.\${DOMAIN}"
