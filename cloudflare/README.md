# Cloudflare Tunnels — WhereQ Universe (PROD)

Infrastructure design + implementation reference for how the WhereQ Universe
exposes services to the internet via **Cloudflare Tunnels** on the PROD host
(the "mini server": hostname `whereq`, `192.168.0.199`, `ssh whereq@whereq`).

> **TL;DR** — Two Cloudflare **accounts**, one **tunnel** each, so two connector
> processes (irreducible). The *whereq family* tunnel runs as a **host systemd
> service** and routes to apps via `http://localhost:<host-port>`. The *ccbus*
> tunnel (currently only `buzz-api`) runs as a **Docker container inside buzz's
> compose** and routes by **container name** over `whereq-network`. All ingress
> (hostname → service) is configured in each account's **Cloudflare dashboard**,
> not on the box and not in any `.env`.

---

## 1. How Cloudflare token tunnels work (the mechanism)

Both tunnels here are **token / remotely-managed** tunnels:

- A tunnel **token** is base64 of `{"a": <account-tag>, "t": <tunnel-id>, "s": <secret>}`.
  `cloudflared tunnel run --token <…>` (or `--token-file <path>`) authenticates a
  connector to **one** tunnel in **one** account.
- **Ingress** (public hostname → local service) is configured in the **Cloudflare
  Zero Trust dashboard** (Tunnels → *tunnel* → Public Hostnames). There is **no
  local `config.yml`** and the tunnel IDs/tokens are **not** in any app `.env`.
- **One connector process = one tunnel = one account.** There is no mode where a
  single `cloudflared` process serves two tunnel IDs, and a tunnel cannot span
  accounts.
- **One tunnel serves many apps.** A single tunnel routes to N services via N
  Public Hostnames. Adding apps to an account does **not** add tunnels — it adds
  ingress rules. (So "the ccbus account will grow" ⇒ still one ccbus connector,
  more Public Hostnames.)

### Routing difference that drives every decision

| Connector runs as… | Reaches a local service via… |
|---|---|
| **Host process** (systemd) | `http://localhost:<published-host-port>` — it is NOT on the docker network, so it cannot use container names. Every app it fronts **must publish a host port**. |
| **Docker container** on `whereq-network` | `http://<container-name>:<port>` — self-documenting, survives container IP changes, internal-only apps need no published port. |

---

## 2. Current PROD state (grounded)

### whereq-family tunnel — host systemd (whereq account)

```ini
# /etc/systemd/system/cloudflared.service   (enabled; running)
[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s
```

- Token file: `/etc/cloudflared/token` (`root:root`, `0600`).
- Fronts the whereq family (flowdesk.top, catobigato, chroniq, whereq-*, and the
  new whereq-monitor) — each via `http://localhost:<port>` (see port registry).

### ccbus tunnel — Docker container (ccbus account)

```yaml
# ~/git/ccbus.cc-backend/docker/docker-compose.prod.yml
cloudflared:
  image: cloudflare/cloudflared:latest
  container_name: cloudflared-ccbus
  command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
  depends_on: [api]            # ← lifecycle-tied to buzz-api
  networks: [whereq-network]   # ← routes to buzz-api by container name
```

- Token comes from `${CLOUDFLARE_TUNNEL_TOKEN}` (buzz repo env; never committed).
- Fronts only `buzz-api` today, routed as `http://buzz-api:8000` (container name).
- The connector is **owned by the buzz-api stack** (buried in its compose,
  `depends_on: api`).

### Where the IDs live

Account tag + tunnel ID are encoded in each token. **Not committed here** — they
live in the respective Cloudflare account dashboard (whereq / ccbus) and in the
token file / buzz env. The `secret` field is a credential; never log or commit it.

---

## 3. Design questions answered

- **Can one systemd service run multiple tunnel IDs in parallel?** No — one
  process serves one tunnel (one account). To run two tunnels on one host you run
  two connector processes (two units/instances or a container + a unit).
- **Does a growing ccbus account need more tunnels?** No — one tunnel, more Public
  Hostnames. What growth exposes is the **coupling** of the shared connector to
  the single `buzz-api` compose.

---

## 4. Options & comparison

Three shapes are on the table:

- **Current** — whereq: host systemd; ccbus: docker container inside buzz compose.
- **Option A** — one **templated** `cloudflared@.service` running BOTH tunnels as
  host systemd instances (`cloudflared@whereq`, `cloudflared@ccbus`).
- **Option B** — extract the ccbus connector into its **own standalone docker
  compose** (not inside buzz), still on `whereq-network`, name-based routing.

### Comparison grid

| Dimension | Current (systemd + docker-in-buzz) | Option A (templated systemd, both) | Option B (standalone docker ccbus) |
|---|---|---|---|
| Connector processes | 2 (one per account — fixed) | 2 | 2 |
| Runtime model | Mixed (host + docker) | **Unified: host systemd** | Mixed (host + docker) |
| Ops surface | `systemctl` + `docker`/compose | **One: `systemctl cloudflared@*`** | `systemctl` + `docker`/compose |
| ccbus tunnel ownership | Buried in buzz compose (`depends_on: api`) | **Decoupled** (own unit) | **Decoupled** (own compose) |
| ccbus → app routing | Container name (`buzz-api:8000`) | `http://localhost:<port>` (host ports required) | Container name (`app:port`) |
| Host-port sprawl | Only whereq family | **Grows with ccbus too** | Only whereq family |
| Token storage | whereq: file; ccbus: app env var | **Both: `/etc/cloudflared/*-token` files** | whereq: file; ccbus: compose env |
| Survives container IP change | n/a (whereq host) / yes (ccbus name) | yes (host ports) | yes (names) |
| cloudflared updates | apt binary + `:latest` image | **One binary path** | apt binary + `:latest` image |
| Migration cost | — | Re-point ccbus ingress `buzz-api:8000` → `localhost:8003` (dashboard, ccbus acct) | Move connector out of buzz compose (ingress unchanged) |

### PROS / CONS

**Current (mixed)**
- ✅ Zero work; ccbus tunnel lives with the app it serves; name-based routing.
- ✅ Fine while ccbus == 1 app.
- ❌ Shared connector coupled to `buzz-api` lifecycle (`depends_on: api`).
- ❌ Two runtime/ops models to reason about.
- ❌ Coupling worsens as the ccbus account grows.

**Option A — templated host systemd (both)**
- ✅ One uniform ops model across both accounts (matches the whereq family, which
  is already host-systemd + host-ports).
- ✅ Decouples the shared connector from any single app.
- ✅ Tokens as root-only files, out of app repos.
- ✅ One `cloudflared` binary/update path.
- ❌ One-time: re-point buzz-api's ingress to `http://localhost:8003` (ccbus
  dashboard) — a **live change on a different app/account**.
- ❌ Every ccbus app must publish a host port (host-port sprawl grows).
- ❌ Loses docker-network name-based routing.

**Option B — standalone docker connector (ccbus)**
- ✅ Decouples from buzz compose while keeping **name-based routing** (cleanest at
  scale, no host-port sprawl, internal-only apps need no port).
- ✅ Ingress unchanged (still `buzz-api:8000`, etc.).
- ❌ Stays a **different** model from the whereq host tunnel (mixed to the end).

---

## 5. Recommendation

The two tunnels are irreducible (two accounts). The current split is fine **today**
(ccbus = 1 app). The decision point is **when the ccbus account gains a 2nd app** —
that is when the "connector buried in buzz's compose" coupling actually bites.

- If standardizing on **operational consistency** (and the whereq family is already
  committed to host-systemd + host-ports) → **Option A** is the right long-term
  standard. Do it as part of adding the 2nd ccbus app, and re-point buzz-api's
  ingress to `localhost:8003` once during that change.
- If optimizing for **docker-native, name-based routing at scale** → **Option B**
  (accept the permanently mixed model).

**Do not migrate for its own sake now.** Optionally pre-stage the templated unit on
the whereq side (zero ccbus impact) so the pattern is ready.

---

## 6. Implementation

### 6a. Expose a NEW whereq-family app (host systemd tunnel) — the standard runbook

Used for `whereq-monitor` (host port **8083**). For any whereq-family app:

1. **Publish a host port** on the app's frontend/entry container (follow the
   `808x` frontend convention — see the port registry).
2. **Cloudflare (whereq account) → Zero Trust → Tunnels → *whereq tunnel* → Public
   Hostnames → Add:**
   - Subdomain/hostname: e.g. `monitor.<domain>`
   - Service: **`http://localhost:<host-port>`**  (host process — NOT a container name)
3. **Keycloak** (realm `flowdesk.top`, client `flowdesk-spa`, at
   `https://www.keytomarvel.com`): add the new external URL to the client's
   **Valid Redirect URIs** and **Web Origins**.
4. Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:<port>/`.

### 6b. Option A — templated systemd unit (when you adopt it)

```ini
# /etc/systemd/system/cloudflared@.service
[Unit]
Description=Cloudflare Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/%i-token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```bash
# tokens as root-only files
sudo install -m 0600 /dev/stdin /etc/cloudflared/whereq-token   # paste whereq token
sudo install -m 0600 /dev/stdin /etc/cloudflared/ccbus-token    # paste ccbus token

sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared@whereq
sudo systemctl enable --now cloudflared@ccbus

# migrate off the old simple unit + docker container
sudo systemctl disable --now cloudflared.service          # old whereq unit
# in ~/git/ccbus.cc-backend: docker compose ... stop/rm cloudflared (or drop the service)
```

**Required for ccbus in Option A:** in the **ccbus** Cloudflare dashboard, change
buzz-api's Public Hostname service from `http://buzz-api:8000` to
`http://localhost:8003` (buzz-api already publishes `8003→8000`). Do this in the
same maintenance window as the connector switch.

---

## 7. Appendix — PROD host-port registry

Published host ports on the mini server (avoid collisions when adding apps):

| Port | Service | Tunnel |
|---|---|---|
| 8000 | flowdesk-api | whereq |
| 8001 | catobigato-api | whereq |
| 8002 | whereq-api | whereq |
| 8003 | buzz-api | **ccbus** |
| 8080 | flowdesk-frontend | whereq |
| 8081 | catobigato-frontend | whereq |
| 8082 | chroniq-frontend | whereq |
| 8083 | **whereq-monitor-frontend** | whereq |
| 3743 | whereq-frontend | whereq |
| 3000 / 3100 / 2020 | grafana / loki / fluent-bit | (internal / observability) |
| 8888 | keycloak-k2m | (k2m) |
| 5432 | whereq-db (shared PostgreSQL) | — |

Frontends follow the `808x` convention; **next free frontend port: 8084**.

---

*Source: infra design discussion, 2026-08-13. Keep this doc in sync with the
systemd unit(s), the ccbus compose, and the Cloudflare dashboards.*
