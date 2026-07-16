# Self-hosting with Cloudflare Tunnel + Traefik

Host many Docker Compose web services on one server, exposed through a single
**Cloudflare Tunnel** — no open inbound ports, no port-forwarding, TLS handled
by Cloudflare at the edge.

```
Internet ──HTTPS──> Cloudflare edge ──tunnel──> cloudflared ──> Traefik ──> your apps
                                                                (routes by hostname)
```

- **cloudflared** — outbound-only connection to Cloudflare. One catch-all rule → Traefik.
- **Traefik** — reverse proxy. Auto-discovers each app from Docker labels, routes by `Host`.
- **Wildcard DNS** (`*.yourdomain` → tunnel) — so new apps need no DNS or tunnel changes.

**Adding an app = write a compose file with 3 Traefik labels and `docker compose up -d`.**
Nothing else to touch.

> **This deployment:** the live domain is **`prestigelocations.ca`** (registrar:
> GoDaddy, DNS delegated to Cloudflare, Microsoft 365 email preserved). The full
> DNS migration runbook is in [docs/cloudflare-godaddy-setup.md](docs/cloudflare-godaddy-setup.md)
> — read it before touching DNS.

## Layout

```
.
├── docker-compose.yml          # infra stack: traefik + cloudflared
├── .env                        # DOMAIN=... (create from .env.example)
├── bootstrap.sh                # one-time setup helper
├── cloudflared/
│   ├── config.yml              # tunnel id + ingress (catch-all -> traefik)
│   └── <TUNNEL_ID>.json        # credentials (gitignored)
├── traefik/
│   ├── traefik.yml             # static config (docker provider, :80)
│   └── dynamic/dashboard.yml   # dashboard router + basic-auth
├── apps/
│   ├── whoami/                 # working example
│   ├── example-node/           # template to copy for real apps
│   └── site/                   # apex site (prestigelocations.ca) — template
└── docs/
    └── cloudflare-godaddy-setup.md   # DNS migration runbook (GoDaddy → Cloudflare)
```

## Prerequisites (Ubuntu server)

- A domain on Cloudflare (using Cloudflare nameservers).
- Docker Engine + Compose plugin:
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"   # log out/in so `docker` works without sudo
  ```
- `cloudflared` CLI (via Cloudflare's apt repo):
  ```bash
  sudo mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list
  sudo apt-get update && sudo apt-get install -y cloudflared
  ```
- `apache2-utils` for `htpasswd` (only if you use Traefik dashboard basic-auth):
  `sudo apt-get install -y apache2-utils`

> **Headless server?** `cloudflared tunnel login` prints a URL instead of opening
> a browser. Copy it to a browser on your laptop, authorize the zone, and the CLI
> on the server continues automatically.

## Setup

### Quick path (scripted)

```bash
cp .env.example .env         # set DOMAIN=yourdomain.com
./bootstrap.sh homelab       # arg = tunnel name; runs the 6 steps below
```

### Manual path (what bootstrap.sh does)

```bash
# 1. Authenticate cloudflared to your Cloudflare account (opens browser)
cloudflared tunnel login

# 2. Create the tunnel — prints a UUID and writes ~/.cloudflared/<UUID>.json
cloudflared tunnel create homelab

# 3. Copy the credentials into this repo (kept out of git)
cp ~/.cloudflared/<UUID>.json ./cloudflared/<UUID>.json

# 4. Put the UUID into cloudflared/config.yml (replace CHANGE_ME_TUNNEL_ID twice)

# 5. Point a wildcard hostname at the tunnel
cloudflared tunnel route dns homelab '*.yourdomain.com'
#   (or add a CNAME  *.yourdomain.com -> <UUID>.cfargotunnel.com  in the dashboard)

# 6. Create the shared network and start the stack
docker network create edge
docker compose up -d
```

Verify: `docker compose logs -f cloudflared` should show a registered connection.

## Deploy an app

Apps are wired into the root project via `include:` in `docker-compose.yml`, so
you run everything from the **repo root** (where `.env` lives):

```bash
docker compose up -d whoami      # one app
docker compose up -d             # infra + all apps
# -> https://whoami.yourdomain.com
```

To add your own service:

1. Copy `apps/example-node` to `apps/<name>`.
2. Add `- apps/<name>/docker-compose.yml` to the `include:` list in the root
   `docker-compose.yml`.
3. Edit the new file:
   - **Service / router / service label names** — must be unique across all apps.
   - **`Host(\`app.${DOMAIN}\`)`** — the subdomain you want.
   - **`loadbalancer.server.port`** — the port your app listens on *inside* the
     container (not a published host port; you don't publish ports at all).
4. `docker compose up -d <service-name>`

> Prefer fully independent stacks instead of `include`? You can run an app on its
> own with `docker compose --env-file ../../.env up -d` from its folder — the
> `--env-file` is required so `${DOMAIN}` resolves.

### Serving the root domain (apex)

`prestigelocations.ca` itself (no subdomain) is served by `apps/site/`. The
wildcard DNS record does **not** cover the apex, so it needs its own tunnel DNS
record and the switch must happen only once the tunnel is running — full steps in
[docs/cloudflare-godaddy-setup.md](docs/cloudflare-godaddy-setup.md) §7.

The three labels every app needs:

```yaml
labels:
  - traefik.enable=true
  - "traefik.http.routers.<name>.rule=Host(`<sub>.${DOMAIN}`)"
  - traefik.http.services.<name>.loadbalancer.server.port=<container-port>
networks:
  - edge          # + declare edge as external at the bottom of the file
```

## Securing internal apps (dashboards, admin panels)

The tunnel makes services reachable from the whole internet. For anything
non-public, add **Cloudflare Access** (Zero Trust → Access → Applications):
require Google/GitHub/email-OTP login *before* traffic reaches your server. It's
free for small teams and far stronger than basic-auth.

The Traefik dashboard (`traefik/dynamic/dashboard.yml`) ships with a basic-auth
placeholder — replace it and set the hostname:

```bash
htpasswd -nbB admin 'a-strong-password'   # paste output into dashboard.yml
# also replace CHANGE_ME_DOMAIN with your domain
```

## Common operations

All from the repo root:

```bash
docker compose up -d                 # infra + all apps
docker compose up -d <service>       # deploy/update one app
docker compose stop <service>        # take one app offline
docker compose logs -f cloudflared   # tunnel connection status
docker compose logs -f traefik       # routing / discovery
docker compose restart cloudflared   # after editing cloudflared/config.yml
```

## Notes & gotchas

- **No host ports.** Apps are reached only via Traefik over the `edge` network,
  so don't `ports:` your apps. Keeps them off the public LAN too.
- **Set Cloudflare SSL/TLS mode to "Full".** Edge→origin runs over the tunnel;
  "Full" is correct. Avoid "Flexible".
- **`network: edge` in `traefik.yml`** tells Traefik which network to reach apps
  on when a container is attached to several — keep every app on `edge`.
- **Secrets:** `.env` and `cloudflared/*.json` are gitignored. Never commit them.
- **One tunnel, many services** is the intended design — you do not need a tunnel
  per app.
