# Migration DNS vers Cloudflare + Tunnel — `prestigelocations.ca`

Runbook de la mise en place de l'hébergement auto-hébergé (serveur local) derrière
un **Cloudflare Tunnel**, pour le domaine **`prestigelocations.ca`**.

## Contexte

- **Registrar : GoDaddy** — on n'y touche pas la propriété du domaine, le client
  continue de payer le renouvellement chez GoDaddy.
- **DNS : délégué à Cloudflare** (on change uniquement les nameservers chez GoDaddy).
- **Email : Microsoft 365 — à préserver.** Le domaine a une messagerie active ; les
  enregistrements associés ne doivent jamais être supprimés.
- **Objectif :** faire répondre `https://prestigelocations.ca` (et des sous-domaines)
  depuis un serveur local, via le tunnel, sans exposer de port entrant.

## Architecture

```
Internet ──HTTPS──> Cloudflare edge ──tunnel──> cloudflared ──> Traefik ──> conteneurs
                                                                (routage par hostname)
```

## Nameservers Cloudflare (cette zone)

```
athena.ns.cloudflare.com
lou.ns.cloudflare.com
```

---

## Enregistrements DNS à PRÉSERVER (email Microsoft 365)

⚠️ **Ne jamais supprimer ces enregistrements.** Supprimer l'un d'eux casse la
messagerie.

| Name | Type | Content | Proxy |
|---|---|---|---|
| `prestigelocations.ca` | MX | `prestigelocations-ca.mail.protection.outlook.com` | DNS only |
| `autodiscover` | CNAME | `autodiscover.outlook.com` | **DNS only** |
| `email` | CNAME | `email.secureserver.net` | **DNS only** |
| `lyncdiscover` | CNAME | `webdir.online.lync.com` | **DNS only** |
| `msoid` | CNAME | `clientconfig.microsoftonline-p.net` | **DNS only** |
| `sip` | CNAME | `sipdir.online.lync.com` | **DNS only** |
| `_sipfederationtls._tcp` | SRV | `... sipfed.online.lync.com` | DNS only |
| `_sip._tls` | SRV | `... sipdir.online.lync.com` | DNS only |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; ...` | DNS only |
| `prestigelocations.ca` | TXT | `v=spf1 include:secureserver.net -all` | DNS only |
| `prestigelocations.ca` | TXT | `NETORG20925572.onmicrosoft.com` (vérif M365) | DNS only |

> **Important :** les 5 CNAME Microsoft (`autodiscover`, `email`, `lyncdiscover`,
> `msoid`, `sip`) doivent être en **« DNS only » (nuage gris)**, jamais « Proxied ».
> Cloudflare les importe parfois en « Proxied » — on les a repassés en gris.

---

## Étapes réalisées

### 1. Cloudflare — ajout du site
- Dashboard → *Add a site* → `prestigelocations.ca` → plan **Free**.
- Cloudflare a scanné et importé les 15 enregistrements existants.

### 2. Cloudflare — correction des CNAME email
- Passé `autodiscover`, `email`, `lyncdiscover`, `msoid`, `sip` de *Proxied* à
  **DNS only**.
- Laissé les 2 `A` de l'apex (ancien site) en *Proxied* — remplacés en étape 6.

### 3. GoDaddy — changement des nameservers
- Domaine → *Nameservers* → *Enter my own nameservers* → remplacé par les 2 NS
  Cloudflare ci-dessus. Aucun autre NS résiduel.

### 4. Attente d'activation
- Cloudflare re-vérifie automatiquement (statut *Invalid/Pending* → *Active*).
- Suivi : `dig +short NS prestigelocations.ca` ou
  https://www.whatsmydns.net/#NS/prestigelocations.ca
- .ca (CIRA) : propagation de quelques minutes à quelques heures.

### 5. Cloudflare — SSL/TLS
- **SSL/TLS → Overview → Full** (pas *Flexible*, pas *Full (strict)*).
- **SSL/TLS → Edge Certificates** : *Always Use HTTPS* = ON,
  *Automatic HTTPS Rewrites* = ON.

---

## Étapes restantes (à faire une fois la zone *Active*)

### 6. Serveur — créer le tunnel

Sur le serveur Ubuntu (voir `README.md` pour l'installation de Docker + cloudflared) :

```bash
cp .env.example .env      # DOMAIN=prestigelocations.ca
./bootstrap.sh homelab    # login CF, création tunnel, DNS wildcard, up
```

`bootstrap.sh` crée aussi le wildcard `*.prestigelocations.ca` → tunnel (proxied),
qui couvre tous les sous-domaines. **Le wildcard ne couvre PAS la racine** — voir
l'étape suivante.

### 7. Bascule de l'apex vers le tunnel (remplace l'ancien site)

⚠️ À faire **seulement** quand la zone est *Active* ET que le tunnel tourne, sinon
`prestigelocations.ca` tombe.

1. Déployer sur le serveur l'app qui sert la racine (voir `apps/site/`).
2. Dans **Cloudflare → DNS**, remplacer les **2 enregistrements `A`** de
   `prestigelocations.ca` par un CNAME vers le tunnel :
   - Supprimer les 2 `A` (`13.248.243.5`, `76.223.105.230`).
   - Ajouter : `prestigelocations.ca` **CNAME** → `<TUNNEL_ID>.cfargotunnel.com`,
     **Proxied**. (Cloudflare aplatit le CNAME à l'apex automatiquement.)

   Ou en CLI : `cloudflared tunnel route dns homelab prestigelocations.ca`
3. Pour `www` : soit un CNAME `www` → `<TUNNEL_ID>.cfargotunnel.com` (Proxied) et une
   règle Traefik `Host(\`www.prestigelocations.ca\`)`, soit une *Redirect Rule*
   Cloudflare `www` → apex.

### 8. Cloudflare Access (apps privées)

Pour tout service non public (dashboard Traefik, admin) :
**Zero Trust → Access → Applications → Add → Self-hosted**, politique *Allow* sur
ton email. À faire après avoir déployé les services.

---

## Rappels

- **Registrar reste GoDaddy** — vérifier que le renouvellement automatique y est actif.
- **Ne jamais supprimer** les enregistrements email listés plus haut.
- **SSL/TLS = Full** (jamais *Flexible*).
- Le trafic entre pour les apps **uniquement via Traefik** sur le réseau `edge` — pas
  de port publié sur les conteneurs.
