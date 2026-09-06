# Self-Hosted Developer Workspace — Design & Source of Truth (Revision 3)

> **What `DESIGN.md` is.** The single reference for `docker-compose.yml` in this directory: what the stack is for,
> every design decision and why, what has been *verified by running it* versus what is still assumed, the
> deployment runbook, and the validation checklist. To get a review, start a new session, paste this whole file,
> then paste the output of §8. The four operative files (compose, Caddyfile, env template, init SQL) are embedded
> in §6 **verbatim from disk** — regenerate this document rather than editing those sections by hand.
>
> Revision history: Rev 1 (distributed services + Nexus + Garage) → Rev 2 (Gitea as IdP, Garage/Nexus removed,
> per-app DB roles) → **Rev 3 (2026-09-06): Caddy TLS with an operator-owned private CA, all HTTP through Caddy,
> three verified config fixes)**. Earlier revisions are described here only; this repository starts at Rev 3.

## 1. Goal and hard constraints

A performance-focused, self-hosted developer workspace and documentation pipeline for a small team:
git hosting + package registry + CI, a wiki, and task/kanban/gantt tracking, with **one login**.

* **100 % Free and Open Source.** No freeware or "community edition" binaries with usage limits.
* **Two deployment profiles, one compose file.** `isolated` (the default) assumes **zero outbound access at
  runtime**: images are transported with `docker save`/`docker load`, Gitea Actions resolve from this instance,
  update checks are off. `connected` assumes the host has internet: images pull normally and Actions may resolve
  upstream. The profile is one line in `.env` and changes exactly two variables — see §1.1. Everything else,
  TLS and identity included, is identical, because in both profiles the services are reached by LAN address and
  have no publicly resolvable name.
* **Target host:** any x86-64 machine with roughly 4 cores and 8 GB RAM running Docker with Compose v2 — a small
  server, a VM, a container host, or a NAS-class appliance. Reserve 1–1.5 GB for the host OS and whatever
  management layer it runs, leaving a realistic container budget of ~6.5 GB. `docker info` should report an
  overlay storage driver (`overlay2`), never `vfs`.
* Small team; performance-per-MB matters more than horizontal scale.

### 1.1 Deployment profiles

| `.env` | `isolated` (default) | `connected` |
|---|---|---|
| `ACTIONS_URL` | `self` — `uses: actions/checkout@v4` resolves to `<ROOT_URL>/actions/checkout`; mirror the actions you need into a local `actions` org first | `github` — resolves upstream |
| `UPDATE_CHECKS` | `false` — Gitea's update checker and Outline's update check are off | `true` |
| images | `docker save` on a build host, `docker load` on the target, verify by image ID (§7 step 9) | `docker compose pull` |

`DEPLOYMENT_PROFILE` itself is a label for humans; the two variables under it are what the compose file reads.
Run `connected` while you evaluate the stack, then flip to `isolated` for the real deployment — nothing else changes.

## 2. Decisions and their reasons

| # | Decision | Why | Status |
|---|---|---|---|
| D1 | **Gitea is the single identity provider** (built-in OAuth2/OIDC). Outline and Vikunja log in via Gitea; Vikunja local auth disabled; registration disabled everywhere. | One user store, no Keycloak/Authelia (each 300 MB+ and one more thing to back up). | Verified: discovery, scopes, claims (§9.2). Browser login flow still to be exercised (§10). |
| D2 | **Gitea's package registry replaces Nexus.** | `sonatype/nexus3` is "Community Edition" with usage limits since 3.77; OSS core covers only Maven/raw/APT; needs ~2.7 GB heap; its key feature (proxying upstreams) is meaningless offline. | Registry `/v2/` answers over TLS (§9.2). `docker push` end-to-end not yet run. |
| D3 | **Outline stores attachments on local disk** (`FILE_STORAGE=local`); Garage/S3 removed. | Single-node S3 for one consumer needed a `garage.toml`, manual layout/key/bucket bootstrap and browser-reachable CORS. | Config accepted at boot; upload not yet exercised. |
| D4 | **Per-application Postgres roles and databases** created once by `init.sql`; apps never connect as superuser; `REVOKE CONNECT … FROM PUBLIC`. | Least privilege, independently rotatable passwords. | Verified (§9.4). |
| D5 | **Caddy terminates TLS for all three apps, signed by an operator-owned root CA** (`certs/root.crt`, generated once with openssl, 10 years). App containers publish no HTTP ports; only Caddy (and Gitea SSH :2222) do. | **Mandatory, not cosmetic:** Outline 1.8 sets its OAuth state cookie `Secure` whenever `NODE_ENV=production` (`server/utils/passport.ts`, `secure: env.isProduction`), independent of `FORCE_HTTPS`/`URL`. Over plain http koa throws *"Cannot send secure cookie over unencrypted connection"* → HTTP 500 on `/auth/oidc`. Once TLS exists for Outline, putting Gitea and Vikunja behind the same CA costs nothing extra and buys: one root to trust per client, `docker push`/`git` over https without `insecure-registries`, no credentials or tokens in clear text on the LAN. | Verified end to end on the reference host (§9.6). |
| D6 | **The root CA is generated by the operator, not by Caddy.** Caddy signs its intermediate and leaf certs with it (`pki { ca local { root { cert/key } } }`). | Caddy *can* generate its own root (`tls internal` alone), but it stores it 0600/0700 root-owned inside `DATA_ROOT/caddy`, so Vikunja (uid 1000) cannot read it for its server-side OIDC calls, and it appears only after first boot (chicken-and-egg with `depends_on`). An openssl-generated `certs/root.crt` is a plain 0644 file, mountable read-only into Outline and Vikunja, trivially backed up and handed to clients. The root carries a **critical name constraint** permitting only the LAN subnet (`permitted;IP:<subnet>`), so even a leaked key cannot mint a certificate for any public host. | Verified (§9.6), incl. a negative test. |
| D7 | **Server-to-server OIDC calls go through the public URL** (`https://HOST_IP:GITEA_PORT`), not `http://gitea:3000`. | Vikunja requires `AUTHURL` == the `issuer` in the discovery document, and Gitea reports its `ROOT_URL` as issuer. Both containers therefore trust `certs/root.crt` (`NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE`) and hairpin to the host's published port. | Verified on the reference host (§9.6). The hairpin is standard Docker behaviour on a native Linux bridge too, but has not been observed there yet (§10). |
| D8 | **Host ports are variables** (`OUTLINE_PORT/GITEA_PORT/VIKUNJA_PORT`, defaults 8081/8082/8083), used consistently in port mappings, all URLs and the Caddyfile (`{$VAR}` placeholders). | The reference host already had 8083 in use. A single `.env` line moves a service; no override file needed. | Verified (Vikunja relocated to 8084). |
| D9 | Immutable version tags; verify transported images by **image ID** (digests are lost by `docker save`/`load`); per-service memory caps; JSON log rotation; `${DATA_ROOT}` parameterised; outbound checks driven by the profile (`UPDATE_CHECKS`, `ACTIONS_URL`). | Reproducible transport; predictable footprint on an 8 GB box; one file for both profiles. | Tags exist; env escaping verified (§9.2). |
| D10 | Rejected early: Plane (air-gap bundles are commercial), OpenProject (monolith, 2.5–3.5 GB idle), Focalboard (sunset). | — | — |

### Config fixes carried into Rev 3 (each one found by running the stack)

1. `VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_AUTHURL` must have **no trailing slash**: Gitea 1.26 reports
   `issuer` as `ROOT_URL` minus the slash (Rev 2 assumed the opposite; Vikunja's exact-match check would fail).
2. `VIKUNJA_SERVICE_JWTSECRET` → **`VIKUNJA_SERVICE_SECRET`** (Vikunja 2.x: "deprecated, will be removed"; logs a WARN).
3. Outline needs TLS (D5). `FORCE_HTTPS=false` only disables the http→https redirect; it does not make the cookie non-Secure.
4. Caddy healthcheck must target `127.0.0.1:2019`, not `localhost` (resolves to `::1` first in the container → refused).
5. Caddy needs `default_sni {$HOST_IP}`: browsers and curl send no SNI for a bare IP; without it the handshake fails
   with *tlsv1 alert internal error* even though the certificate was issued.

## 3. Current stack

| Component | Image | Role | Cap | Idle RSS measured |
|---|---|---|---|---|
| Caddy | `caddy:2.10.2-alpine` | TLS entry point, private CA signer | 128 M | 11–16 MB |
| PostgreSQL | `postgres:16-alpine` | shared DB, one role/db per app | 512 M | ~50 MB |
| Valkey | `valkey/valkey:8.1-alpine` | Outline queues/pubsub/collab (no persistence) | 128 M | ~13 MB |
| Gitea | `gitea/gitea:1.26` | git, LFS, packages, Actions, **OIDC provider** | 1 G | 90–110 MB |
| Outline | `outlinewiki/outline:1.8.0` | wiki, local file storage, OIDC → Gitea | 1 G | 340 MB (520 MB right after migrations) |
| Vikunja | `vikunja/vikunja:2.3.0` | tasks/kanban/gantt, OIDC → Gitea only | 256 M | ~15 MB |

Whole stack idle: **~540 MB**. Sum of caps: 3 GB — well inside the ~6.5 GB budget; no Postgres tuning is justified
by these numbers.

## 4. Network and trust model

```
 user's browser / git / docker CLI                     (trusts certs/root.crt once)
        │ https://HOST_IP:8081  https://HOST_IP:8082  https://HOST_IP:8083        ssh://git@HOST_IP:2222
        ▼                                                                             │
 ┌── caddy ──────────────────────────────────────────────────────────┐                │
 │  leaf certs (SAN = HOST_IP) ← intermediate ← certs/root.crt       │                │
 └───┬───────────────────────┬───────────────────────┬───────────────┘                │
     ▼ outline:3000          ▼ gitea:3000            ▼ vikunja:3456  ◄────────────────┘ gitea:22
     │                       ▲        ▲              │
     │ token/userinfo        │        │  discovery/token/userinfo
     └── https://HOST_IP:8082┘        └── https://HOST_IP:8082 ── (hairpin via host, trusts /certs/root.crt)
     postgres:5432 (roles outline/gitea/vikunja)      valkey:6379 (outline only)
```

* **Who trusts what.** Clients trust `certs/root.crt` (once, per machine — §7 step 8). Outline trusts it via
  `NODE_EXTRA_CA_CERTS`; Vikunja via `SSL_CERT_FILE` (Go replaces the system bundle with that file, which is fine:
  offline, it only ever talks to Gitea). Gitea makes no outbound TLS calls in this design.
* **Terminology.** This is an *online root*: the signing key lives on the running server (inside the Caddy container).
  "Online" is PKI jargon for that and has nothing to do with internet access. Caddy's own automatic CA is also an
  online root with the same 10-year lifetime (observed: its auto-generated root expired 2036). The *offline-root*
  variant (root key kept on removable media; Caddy given only the root cert plus an intermediate cert/key via
  `pki > ca > intermediate`) is supported by Caddy but not adopted: the intermediate would need manual re-issue
  before expiry or the stack goes dark.
* **CA lifecycle.** `certs/root.key` never leaves the compose directory (0600). Caddy issues a 7-day intermediate and
  12-hour leaf certificates automatically and forever; nothing expires on the operator's side for 10 years.
  **Rotating or replacing the root**, in this order: replace `certs/` → `rm -rf ${DATA_ROOT}/caddy/*` (Caddy keeps a
  stale intermediate otherwise — observed) → `docker compose up -d` → `docker compose restart outline vikunja`
  (file bind mounts keep the old inode of `root.crt`; observed as a `bad end line` PEM error in Outline) → re-trust
  on clients.
* **Blast radius of trusting the root.** The name constraint limits what a leaked key can forge to hosts inside the
  LAN subnet. OpenSSL, Chrome and Firefox enforce name constraints on user-added roots; Apple's verifier is not
  confirmed, so treat it as defence in depth. On the server the key is readable only by root; anyone who has that
  already owns the box.
* **Changing `HOST_IP`** (moving the stack to another host) does not touch the CA: Caddy re-issues leaves; you only re-create the two
  OAuth2 redirect URIs in Gitea (§7 step 6) and users type a new address.
* **No plain http anywhere.** A plain-http request to a TLS port gets Caddy's 400 (observed). The SSH port is the
  only non-TLS listener.

## 5. Directory layout

```
selfhosted-workspace/
├── DESIGN.md              this document — the source of truth
├── README.md              repository front page
├── LICENSE                MIT
├── docker-compose.yml     the stack (embedded in §6.1)
├── Caddyfile              TLS + reverse proxy, env placeholders (§6.2)
├── env.example → .env     all host-specific values and secrets, chmod 600 (§6.3)
├── init.sql               Postgres first-boot provisioning (§6.4)
├── certs/root.crt  0644   distribute to every client
├── certs/root.key  0600   never leaves this directory
├── .gitignore             excludes everything in the "private" column below
└── ${DATA_ROOT}/{postgres,gitea,outline,vikunja/files,caddy}   runtime state (outside the repo)
```

### 5.1 Public vs private — for keeping this directory in a public git repository

| Public (commit) | Private (never commit; `.gitignore`d) | Why |
|---|---|---|
| `docker-compose.yml`, `Caddyfile`, `init.sql`, `env.example`, `DESIGN.md`, `README.md`, `LICENSE` | `.env` | every DB password, Outline/Vikunja secrets, Gitea admin password, OIDC client secrets |
| | `certs/root.key` | the CA private key: whoever has it can impersonate every service to every client that trusts the root |
| | `certs/root.crt` | not secret (it is handed to clients), but per-cluster; keep it with the cluster's secrets |
| | `${DATA_ROOT}/` (`data/` on the Mac) | databases, repositories, `gitea/conf/app.ini` (contains generated JWT/LFS secrets), SSH host keys |
| | `POC-MAC-NOTES.md`, `*.tgz`, `*.ids` | device-specific notes with LAN addresses; image bundles |

The compose file itself contains no secrets by design (§6.1 header): every sensitive value is a `${VAR}` read from `.env`.
`HOST_IP` and `DATA_ROOT` are not secrets but are per-cluster, which is why they also live in `.env`.

**Keeping the secrets you still need, per cluster, without exposing them.** Encrypt them with
[age](https://github.com/FiloSottile/age) (FOSS, single static binary, works offline) and commit only the ciphertext:

```bash
brew install age                      # Debian: apt install age. One identity per person, never per cluster.
age-keygen -o ~/.config/age/keys.txt  # prints "public key: age1…"; back up keys.txt in your password manager
mkdir -p clusters/<name>
age -r age1…  -o clusters/<name>/env.age       .env
age -r age1…  -o clusters/<name>/root.key.age  certs/root.key
cp certs/root.crt clusters/<name>/root.crt     # public, fine in clear
# on another device, after cloning:
age -d -i ~/.config/age/keys.txt clusters/<name>/env.age      > .env            && chmod 600 .env
age -d -i ~/.config/age/keys.txt clusters/<name>/root.key.age > certs/root.key  && chmod 600 certs/root.key
cp clusters/<name>/root.crt certs/root.crt
```

Rules: (1) the age identity file is the one secret that lives outside git — password manager or USB;
(2) re-encrypt after every change to `.env` (new OIDC secrets, rotated passwords); (3) on the air-gapped box either
copy the static `age` binary or decrypt on your laptop and copy `.env` + `certs/` over; (4) a value pushed in clear
even once stays in git history forever — rewrite history and rotate it; a pre-commit scanner such as
[gitleaks](https://github.com/gitleaks/gitleaks) (FOSS) is a cheap safety net. If you later want diffable, key-visible
encrypted env files, [SOPS](https://github.com/getsops/sops) with age as backend is the step up; age alone is enough to start.

## 6. Files (verbatim from disk)

### 6.1 `docker-compose.yml`

```yaml
# Self-hosted developer workspace — Revision 3
#   Caddy (TLS, private CA) in front of
#   Outline (wiki) + Gitea (git, packages, actions, OIDC provider) + Vikunja (tasks)
#   on one shared PostgreSQL and one shared Valkey.
#
# Companion files (same directory): .env (copy env.example), init.sql, Caddyfile,
#                                   certs/root.crt + certs/root.key (generated once, see runbook)
#
# Authentication: Gitea is the single identity provider. Outline and Vikunja both log in
# through Gitea's built-in OIDC provider; users are managed in Gitea only.
#
# Network shape
#   browser ── https://HOST_IP:{8081,8082,8083} ──> caddy ──> outline:3000 / gitea:3000 / vikunja:3456
#   git ssh ── ssh://git@HOST_IP:2222 ───────────> gitea:22 (direct, no TLS proxy)
#   Only caddy (and gitea :22) publish host ports. App containers are reachable only on the
#   compose network. Server-to-server OIDC calls (outline/vikunja -> gitea) go through
#   https://HOST_IP:8082 like a browser would, so the issuer string matches exactly; both
#   containers trust certs/root.crt for that hop.
#
# Deployment profiles (set DEPLOYMENT_PROFILE in .env; it selects the two variables below)
#   isolated   no outbound access at runtime. Images arrive by `docker save`/`docker load`,
#              Actions resolve from this instance, update checks are off. The default.
#   connected  the host has internet. Images pull normally and Actions may resolve upstream.
#   Everything else is identical between the two, TLS included: both serve LAN clients
#   from a private CA, because neither profile has a publicly resolvable name.
#
# Conventions
#   * All persistent state lives under ${DATA_ROOT}, an absolute host path. Pick one your
#     container runtime is allowed to bind-mount; some managed Docker UIs share only
#     specific parent directories.
#   * Every image is a variable so the same file runs in both profiles. Use immutable
#     version tags. Digests do NOT survive `docker save`/`docker load`, so verify
#     transported images by image ID (docker image inspect --format '{{.Id}}').
#   * Secrets live only in .env (chmod 600) and certs/root.key (chmod 600).
#   * Removed on purpose: Garage (Outline stores files locally since 0.72) and
#     Nexus (Gitea's package registry covers hosted artifacts; proxying is moot offline).

name: workspace

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:

  # ---------------------------------------------------------------------------
  # Caddy — the only HTTP entry point. Terminates TLS with the operator's root CA.
  # ---------------------------------------------------------------------------
  caddy:
    image: ${CADDY_IMAGE:-caddy:2.10.2-alpine}
    container_name: workspace-caddy
    restart: unless-stopped
    ports:
      - "${OUTLINE_PORT:-8081}:${OUTLINE_PORT:-8081}"
      - "${GITEA_PORT:-8082}:${GITEA_PORT:-8082}"
      - "${VIKUNJA_PORT:-8083}:${VIKUNJA_PORT:-8083}"
    environment:
      # consumed by {$VAR} placeholders in the Caddyfile
      HOST_IP: ${HOST_IP:?set HOST_IP in .env}
      OUTLINE_PORT: ${OUTLINE_PORT:-8081}
      GITEA_PORT: ${GITEA_PORT:-8082}
      VIKUNJA_PORT: ${VIKUNJA_PORT:-8083}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      # root CA: Caddy signs a short-lived intermediate + leaf certs with this key.
      - ./certs:/certs:ro
      # intermediate/leaf certs and locks; harmless to lose (re-issued from the root).
      - ${DATA_ROOT:-/opt/workspace}/caddy:/data
    healthcheck:
      # config loaded and serving. Admin API is bound to 127.0.0.1 inside the container only
      # (use the literal IP: "localhost" resolves to ::1 first in the container).
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:2019/config/"]
      interval: 5s
      timeout: 3s
      retries: 12
    deploy:
      resources:
        limits:
          memory: 128M
    logging: *default-logging

  # ---------------------------------------------------------------------------
  # Shared backends
  # ---------------------------------------------------------------------------
  postgres:
    image: ${POSTGRES_IMAGE:-postgres:16-alpine}
    container_name: workspace-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?copy env.example to .env and fill it in}
      # Read by init.sql on FIRST boot only, to create the per-app roles.
      OUTLINE_DB_PASSWORD: ${OUTLINE_DB_PASSWORD}
      GITEA_DB_PASSWORD: ${GITEA_DB_PASSWORD}
      VIKUNJA_DB_PASSWORD: ${VIKUNJA_DB_PASSWORD}
    volumes:
      - ${DATA_ROOT:-/opt/workspace}/postgres:/var/lib/postgresql/data
      # Runs once, only when the data directory is empty. Creates roles + databases.
      - ./init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro
    healthcheck:
      # -h 127.0.0.1 forces TCP. Without it pg_isready hits the unix socket, which is
      # already up while the socket-only bootstrap server runs init scripts, and
      # depends_on would release the apps before they can actually connect.
      test: ["CMD-SHELL", "pg_isready -U postgres -h 127.0.0.1"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 20s
    deploy:
      resources:
        limits:
          memory: 512M
    logging: *default-logging

  valkey:
    image: ${VALKEY_IMAGE:-valkey/valkey:8.1-alpine}
    container_name: workspace-valkey
    restart: unless-stopped
    # Outline uses it for job queues, websocket pub/sub and collaboration state.
    # Nothing here needs to survive a restart, so persistence is off.
    command: ["valkey-server", "--save", "", "--appendonly", "no"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 6
    deploy:
      resources:
        limits:
          memory: 128M
    logging: *default-logging

  # ---------------------------------------------------------------------------
  # Gitea — git hosting, package registry, Actions, and the OIDC provider
  # ---------------------------------------------------------------------------
  gitea:
    image: ${GITEA_IMAGE:-gitea/gitea:1.26}
    container_name: workspace-gitea
    restart: unless-stopped
    ports:
      - "2222:22"                                  # HTTP is served through caddy only
    volumes:
      # Repos, LFS objects, SSH host keys, app.ini (incl. generated JWT secrets).
      - ${DATA_ROOT:-/opt/workspace}/gitea:/data
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      # --- database (role created by init.sql) ---
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: postgres:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: ${GITEA_DB_PASSWORD}
      GITEA__database__SSL_MODE: disable
      # --- URLs: browsers, clone URLs, registry name and OIDC issuer all derive from ROOT_URL ---
      # Verified on 1.26: the OIDC discovery `issuer` is ROOT_URL WITHOUT its trailing slash.
      GITEA__server__ROOT_URL: https://${HOST_IP:?}:${GITEA_PORT:-8082}/
      GITEA__server__DOMAIN: ${HOST_IP}
      GITEA__server__SSH_DOMAIN: ${HOST_IP}
      GITEA__server__SSH_PORT: "2222"
      GITEA__server__LFS_START_SERVER: "true"
      # Only caddy can reach :3000 (not published), so trust its X-Forwarded-For for client IPs in logs.
      GITEA__security__REVERSE_PROXY_TRUSTED_PROXIES: "*"
      # --- unattended, closed environment ---
      GITEA__security__INSTALL_LOCK: "true"          # no web installer; admin via one `gitea admin user create`
      GITEA__service__DISABLE_REGISTRATION: "true"   # users are created by an admin
      GITEA__repository__DEFAULT_BRANCH: main
      GITEA__mailer__ENABLED: "false"
      # section names containing "." are escaped as _0X2E_ in env-var form (verified: lands in [cron.update_checker])
      GITEA__cron_0X2E_update_checker__ENABLED: "${UPDATE_CHECKS:-false}"   # isolated: no phone-home attempts
      # --- features ---
      GITEA__oauth2__ENABLED: "true"                 # OIDC provider for Outline and Vikunja
      GITEA__packages__ENABLED: "true"               # container/maven/npm/pypi/... registry
      GITEA__actions__ENABLED: "true"
      # isolated ("self"): `uses: actions/checkout@v4` resolves to <ROOT_URL>/actions/checkout,
      #   so mirror the actions you use into a local "actions" org before running workflows.
      # connected ("github"): they resolve upstream as usual.
      GITEA__actions__DEFAULT_ACTIONS_URL: ${ACTIONS_URL:-self}
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3000/api/healthz"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 1G
    logging: *default-logging

  # ---------------------------------------------------------------------------
  # Outline — wiki. Local file storage, Gitea as identity provider.
  # ---------------------------------------------------------------------------
  outline:
    image: ${OUTLINE_IMAGE:-outlinewiki/outline:1.8.0}
    container_name: workspace-outline
    restart: unless-stopped
    volumes:
      # Attachments/images. The container runs as uid 1001 — chown 1001:1001 on the host.
      - ${DATA_ROOT:-/opt/workspace}/outline:/var/lib/outline/data
      # Trust our CA for the server-side token/userinfo calls to https://HOST_IP:GITEA_PORT
      - ./certs/root.crt:/certs/root.crt:ro
    environment:
      NODE_ENV: production
      NODE_EXTRA_CA_CERTS: /certs/root.crt
      URL: https://${HOST_IP}:${OUTLINE_PORT:-8081}   # browser-facing URL; must match what users type
      PORT: "3000"
      # Outline trusts X-Forwarded-Proto from caddy (koa app.proxy=true). The OAuth state
      # cookie is Secure whenever NODE_ENV=production, which is why TLS is mandatory.
      FORCE_HTTPS: "false"               # moot: there is no plain-http listener anyway
      ENABLE_UPDATES: "${UPDATE_CHECKS:-false}"   # isolated: no update checks
      WEB_CONCURRENCY: "1"               # one web process is plenty for a small team
      LOG_LEVEL: info
      DEFAULT_LANGUAGE: en_US
      SECRET_KEY: ${OUTLINE_SECRET_KEY}         # 64 hex chars
      UTILS_SECRET: ${OUTLINE_UTILS_SECRET}     # 64 hex chars
      # --- database / cache ---
      DATABASE_URL: postgres://outline:${OUTLINE_DB_PASSWORD}@postgres:5432/outline
      PGSSLMODE: disable                 # production mode otherwise insists on TLS to PG
      REDIS_URL: redis://valkey:6379
      # --- file storage: local disk instead of S3 ---
      FILE_STORAGE: local
      FILE_STORAGE_LOCAL_ROOT_DIR: /var/lib/outline/data
      FILE_STORAGE_UPLOAD_MAX_SIZE: "262144000"   # 250 MB
      # --- authentication: Gitea's built-in OIDC provider ---
      # Create the app in Gitea (admin user -> Settings -> Applications, or the API):
      #   Redirect URI:        https://${HOST_IP}:${OUTLINE_PORT}/auth/oidc.callback
      #   Confidential client: yes
      # then put the generated id/secret in .env.
      OIDC_CLIENT_ID: ${OUTLINE_OIDC_CLIENT_ID:-}
      OIDC_CLIENT_SECRET: ${OUTLINE_OIDC_CLIENT_SECRET:-}
      OIDC_AUTH_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/authorize
      OIDC_TOKEN_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/access_token
      OIDC_USERINFO_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/userinfo
      OIDC_USERNAME_CLAIM: preferred_username
      OIDC_DISPLAY_NAME: Gitea
      OIDC_SCOPES: openid profile email  # "email" is mandatory: Outline requires an email claim
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 1G
    logging: *default-logging

  # ---------------------------------------------------------------------------
  # Vikunja — tasks / kanban / gantt. Login only via Gitea (OIDC); no local accounts.
  # ---------------------------------------------------------------------------
  vikunja:
    image: ${VIKUNJA_IMAGE:-vikunja/vikunja:2.3.0}
    container_name: workspace-vikunja
    restart: unless-stopped
    volumes:
      # Task attachments. Container runs as PUID/PGID below — chown 1000:1000 on the host.
      - ${DATA_ROOT:-/opt/workspace}/vikunja/files:/app/vikunja/files
      # Trust our CA for the discovery/token/userinfo calls to https://HOST_IP:GITEA_PORT
      - ./certs/root.crt:/certs/root.crt:ro
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: ${TZ:-UTC}
      SSL_CERT_FILE: /certs/root.crt                        # Go: replaces the system CA bundle
      VIKUNJA_SERVICE_PUBLICURL: https://${HOST_IP}:${VIKUNJA_PORT:-8083}/   # share links, CalDAV
      # Vikunja 2.x: service.secret replaces the deprecated service.jwtsecret (logs a WARN if used).
      VIKUNJA_SERVICE_SECRET: ${VIKUNJA_JWT_SECRET}
      VIKUNJA_SERVICE_TIMEZONE: ${TZ:-UTC}
      VIKUNJA_SERVICE_ENABLEREGISTRATION: "false"          # no self-service local sign-up
      # --- authentication: Gitea via OIDC (users auto-created on first login) ---
      # Create the app in Gitea (admin user -> Settings -> Applications, or the API):
      #   Redirect URI:        https://${HOST_IP}:${VIKUNJA_PORT}/auth/openid/gitea
      #                        (last segment = provider key = "GITEA" below, lower-cased)
      #   Confidential client: yes
      # AUTHURL is the OIDC issuer. Vikunja fetches <AUTHURL>/.well-known/openid-configuration
      # and requires the issuer string to match EXACTLY. Gitea 1.26 reports the issuer WITHOUT
      # a trailing slash, so there must be none here.
      VIKUNJA_AUTH_LOCAL_ENABLED: "false"                   # set "true" for a break-glass local login
      VIKUNJA_AUTH_OPENID_ENABLED: "true"
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_NAME: Gitea
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_AUTHURL: https://${HOST_IP}:${GITEA_PORT:-8082}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_CLIENTID: ${VIKUNJA_OIDC_CLIENT_ID:-}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_CLIENTSECRET: ${VIKUNJA_OIDC_CLIENT_SECRET:-}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_SCOPE: openid profile email
      # --- database (role created by init.sql) ---
      VIKUNJA_DATABASE_TYPE: postgres
      VIKUNJA_DATABASE_HOST: postgres:5432
      VIKUNJA_DATABASE_DATABASE: vikunja
      VIKUNJA_DATABASE_USER: vikunja
      VIKUNJA_DATABASE_PASSWORD: ${VIKUNJA_DB_PASSWORD}
      VIKUNJA_DATABASE_SSLMODE: disable
      VIKUNJA_MAILER_ENABLED: "false"
      VIKUNJA_FILES_MAXSIZE: 50MB
      # Default in-memory cache is fine at this scale. To share Valkey instead:
      # VIKUNJA_CACHE_ENABLED: "true"
      # VIKUNJA_CACHE_TYPE: redis
      # VIKUNJA_REDIS_ENABLED: "true"
      # VIKUNJA_REDIS_HOST: valkey:6379
    depends_on:
      postgres:
        condition: service_healthy
      gitea:
        condition: service_healthy       # discovery document is fetched at startup ...
      caddy:
        condition: service_healthy       # ... through caddy, over TLS
    deploy:
      resources:
        limits:
          memory: 256M
    logging: *default-logging
```

### 6.2 `Caddyfile`

```caddyfile
# Caddy — TLS termination for the whole workspace, signed by the operator's own root CA.
# Placeholders {$VAR} are filled from the caddy service's environment (see docker-compose.yml).
#
# Why TLS at all in an air-gapped LAN: Outline 1.8 sets its OAuth state cookie Secure=true
# whenever NODE_ENV=production, so OIDC login over plain http fails with HTTP 500.
# Putting every app behind the same CA also lets `docker push` and `git` over https work
# with one trusted root instead of insecure-registries.
{
	# admin API stays inside the container (never published); used by the healthcheck
	admin localhost:2019
	auto_https disable_redirects   # no :80 listeners exist
	skip_install_trust             # do not try to install the root into the container's store
	# browsers and curl send no SNI when the address is a bare IP; serve this cert then
	default_sni {$HOST_IP}
	pki {
		ca local {
			name "Workspace Root CA"
			root {
				cert /certs/root.crt
				key  /certs/root.key
			}
		}
	}
	servers {
		protocols h1 h2          # h3 needs UDP ports; keep it TCP-only
	}
}

https://{$HOST_IP}:{$OUTLINE_PORT} {
	tls internal
	reverse_proxy outline:3000
}

https://{$HOST_IP}:{$GITEA_PORT} {
	tls internal
	reverse_proxy gitea:3000
}

https://{$HOST_IP}:{$VIKUNJA_PORT} {
	tls internal
	reverse_proxy vikunja:3456
}
```

### 6.3 `env.example`

```dotenv
# Copy to .env, fill in, then: chmod 600 .env
# Every value is plain text; keep to [A-Za-z0-9] for passwords so they are safe inside URLs.
# No inline comments after values on the same line.

# --- deployment profile -------------------------------------------------------
# isolated  : no outbound access at runtime. Images arrive by docker save/load, Gitea Actions
#             resolve from this instance, update checks are off. Safe default.
# connected : the host has internet. Images pull normally, Actions may resolve upstream.
# The profile changes only the two variables under it; TLS and everything else are identical.
DEPLOYMENT_PROFILE=isolated
ACTIONS_URL=self                # isolated: self   | connected: github
UPDATE_CHECKS=false             # isolated: false  | connected: true

# --- deployment ---------------------------------------------------------------
# Address users type into their browser: a LAN IP or a LAN DNS name. Changing it later means
# re-issuing the two OAuth2 redirect URIs in Gitea; the CA is unaffected, so no client
# re-trusts anything. Pick it once.
HOST_IP=192.168.1.50
# Absolute host path for all persistent state. Must be bind-mountable by your container
# runtime; some managed Docker UIs share only specific parent directories.
DATA_ROOT=/opt/workspace
TZ=UTC
# Host ports served by caddy (TLS). Change only if something else already uses one of them.
OUTLINE_PORT=8081
GITEA_PORT=8082
VIKUNJA_PORT=8083

# --- images (immutable tags; bump deliberately) ---------------------------------
CADDY_IMAGE=caddy:2.10.2-alpine
POSTGRES_IMAGE=postgres:16-alpine
VALKEY_IMAGE=valkey/valkey:8.1-alpine
GITEA_IMAGE=gitea/gitea:1.26
OUTLINE_IMAGE=outlinewiki/outline:1.8.0
VIKUNJA_IMAGE=vikunja/vikunja:2.3.0

# --- secrets: fill all seven with one command (GNU sed shown; BSD sed needs -i '') ------
#   for k in POSTGRES_PASSWORD OUTLINE_DB_PASSWORD GITEA_DB_PASSWORD VIKUNJA_DB_PASSWORD; do
#     sed -i "s/^$k=.*/$k=$(openssl rand -hex 24)/" .env; done
#   for k in OUTLINE_SECRET_KEY OUTLINE_UTILS_SECRET VIKUNJA_JWT_SECRET; do
#     sed -i "s/^$k=.*/$k=$(openssl rand -hex 32)/" .env; done
POSTGRES_PASSWORD=
OUTLINE_DB_PASSWORD=
GITEA_DB_PASSWORD=
VIKUNJA_DB_PASSWORD=
OUTLINE_SECRET_KEY=
OUTLINE_UTILS_SECRET=
VIKUNJA_JWT_SECRET=

# --- Gitea bootstrap admin (used by the runbook's `gitea admin user create`, not by compose) ---
GITEA_ADMIN_USER=admin
GITEA_ADMIN_PASSWORD=
GITEA_ADMIN_EMAIL=admin@workspace.local

# --- OIDC clients, created in Gitea AFTER it is up (runbook step 5) ----------------
#   "Outline"  redirect https://<HOST_IP>:<OUTLINE_PORT>/auth/oidc.callback   confidential: yes
#   "Vikunja"  redirect https://<HOST_IP>:<VIKUNJA_PORT>/auth/openid/gitea    confidential: yes
OUTLINE_OIDC_CLIENT_ID=
OUTLINE_OIDC_CLIENT_SECRET=
VIKUNJA_OIDC_CLIENT_ID=
VIKUNJA_OIDC_CLIENT_SECRET=
```

### 6.4 `init.sql`

```sql
-- init.sql — PostgreSQL first-boot provisioning for the workspace stack.
--
-- HOW IT RUNS
--   Mounted at /docker-entrypoint-initdb.d/10-init.sql. The official postgres image
--   executes it exactly once: the first time the container starts on an EMPTY data
--   directory. It never runs again. To re-run it, stop the stack and wipe
--   ${DATA_ROOT}/postgres (this destroys all data).
--
--   psql runs this as the superuser over the local socket while the apps are still
--   blocked by the healthcheck, so the databases exist before anything connects.
--
-- SECRETS
--   Passwords are read from the container environment (docker-compose.yml passes them
--   through from .env) via psql's backtick expansion. This file contains none.

\set ON_ERROR_STOP on

\set outline_pw `printf %s "$OUTLINE_DB_PASSWORD"`
\set gitea_pw   `printf %s "$GITEA_DB_PASSWORD"`
\set vikunja_pw `printf %s "$VIKUNJA_DB_PASSWORD"`

-- One role per application: isolation, least privilege, independently rotatable.
CREATE ROLE outline LOGIN PASSWORD :'outline_pw';
CREATE ROLE gitea   LOGIN PASSWORD :'gitea_pw';
CREATE ROLE vikunja LOGIN PASSWORD :'vikunja_pw';

-- OWNER matters: since PG15 the public schema is owned by the database owner, so each
-- app role can create its tables without any extra GRANTs.
CREATE DATABASE outline OWNER outline;
CREATE DATABASE gitea   OWNER gitea;
CREATE DATABASE vikunja OWNER vikunja;

-- Only the owning role may connect to its database.
REVOKE CONNECT ON DATABASE outline, gitea, vikunja FROM PUBLIC;

-- Outline's migrations expect these extensions. Provision them as superuser now so
-- the outline role never needs CREATE EXTENSION rights.
\connect outline
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Gitea and Vikunja need no extensions; their migrations run on first app start.
```

## 7. Deployment runbook

```bash
# 0. prerequisites: docker + compose v2, openssl, curl. `docker info | grep -i storage` must say overlay2.

# 1. configuration
cp env.example .env && chmod 600 .env
#    set DEPLOYMENT_PROFILE (+ ACTIONS_URL/UPDATE_CHECKS), HOST_IP (the address users will type), DATA_ROOT, TZ,
#    ports if 8081-8083 collide, then generate the seven secrets and the admin password:
for k in POSTGRES_PASSWORD OUTLINE_DB_PASSWORD GITEA_DB_PASSWORD VIKUNJA_DB_PASSWORD; do sed -i "s/^$k=.*/$k=$(openssl rand -hex 24)/" .env; done
for k in OUTLINE_SECRET_KEY OUTLINE_UTILS_SECRET VIKUNJA_JWT_SECRET; do sed -i "s/^$k=.*/$k=$(openssl rand -hex 32)/" .env; done
sed -i "s/^GITEA_ADMIN_PASSWORD=.*/GITEA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20)/" .env
. ./.env

# 2. root CA — once for the lifetime of the deployment (10 years). Back up certs/ with the secrets (§5.1).
#    Name-constrained to the LAN /24 of HOST_IP: a leaked key cannot forge certs for anything outside it.
#    Widen the mask (or add a second "permitted;IP:…") if the stack will later sit in another subnet.
mkdir -p certs
SUBNET="${HOST_IP%.*}.0/255.255.255.0"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=Workspace Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;IP:$SUBNET" \
  -keyout certs/root.key -out certs/root.crt
chmod 600 certs/root.key; chmod 644 certs/root.crt
openssl x509 -in certs/root.crt -noout -ext nameConstraints    # sanity check

# 3. data directories (ownership matches the container uids; caddy runs as root and needs nothing)
mkdir -p "$DATA_ROOT"/{postgres,outline,gitea,vikunja/files,caddy}
chown 1001:1001 "$DATA_ROOT/outline"
chown -R 1000:1000 "$DATA_ROOT/gitea" "$DATA_ROOT/vikunja"

# 4. backends, TLS entry point and the identity provider first
docker compose up -d postgres valkey caddy gitea
docker compose ps        # wait until all four are (healthy)

# 5. Gitea admin (no web installer: INSTALL_LOCK=true)
docker exec -u git workspace-gitea gitea admin user create --admin \
  --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" --email "$GITEA_ADMIN_EMAIL" --must-change-password=false

# 6. OAuth2 clients. Gitea's API has no endpoint for *site-wide* applications, so create them as apps owned by
#    the admin user (functionally identical for login). The UI equivalent is admin -> Settings -> Applications.
API="https://$HOST_IP:$GITEA_PORT/api/v1"; AUTH="$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD"; CA=certs/root.crt
mkapp() { curl -sf --cacert $CA -u "$AUTH" -H 'Content-Type: application/json' -X POST "$API/user/applications/oauth2" \
          -d "{\"name\":\"$1\",\"redirect_uris\":[\"$2\"],\"confidential_client\":true}"; }
mkapp Outline "https://$HOST_IP:$OUTLINE_PORT/auth/oidc.callback" | tee /dev/stderr | python3 -c \
  'import json,sys;a=json.load(sys.stdin);print(f"OUTLINE_OIDC_CLIENT_ID={a[\"client_id\"]}\nOUTLINE_OIDC_CLIENT_SECRET={a[\"client_secret\"]}")'
mkapp Vikunja "https://$HOST_IP:$VIKUNJA_PORT/auth/openid/gitea" | python3 -c \
  'import json,sys;a=json.load(sys.stdin);print(f"VIKUNJA_OIDC_CLIENT_ID={a[\"client_id\"]}\nVIKUNJA_OIDC_CLIENT_SECRET={a[\"client_secret\"]}")'
#    paste the four printed lines into .env (the secret is shown only once), then:
docker compose up -d

# 7. verify — §8

# 8. trust the root CA on every client machine (once). Distribute certs/root.crt (public, safe to share).
#    macOS:    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.crt
#    Windows:  certutil -addstore -f ROOT root.crt              (admin prompt)
#    Debian:   sudo cp root.crt /usr/local/share/ca-certificates/workspace-root.crt && sudo update-ca-certificates
#    Firefox:  uses its own store: Settings -> Certificates -> Import, or about:config security.enterprise_roots.enabled=true
#    git:      macOS/Windows use the OS store (Windows: git config --global http.sslBackend schannel);
#              Linux picks up update-ca-certificates; fallback: git config --global http.sslCAInfo /path/root.crt
#    docker:   Linux daemon: sudo install -D -m 644 root.crt /etc/docker/certs.d/$HOST_IP:$GITEA_PORT/ca.crt  (no restart)
#              Docker Desktop: trust in the OS store, then restart Docker Desktop
#    act_runner host (Gitea Actions): system store as above; job containers that pull from the registry need it too.

# 9. images
#    connected profile: pull straight onto the target.
#    isolated profile: pull on a build host that has internet, then carry the archive across.
docker compose pull
docker save $(docker compose config --images) | gzip > workspace-images.tgz
docker compose config --images | xargs -n1 docker image inspect --format '{{.RepoTags}} {{.Id}}' > workspace-images.ids
#    on the target: gzip -dc workspace-images.tgz | docker load; compare IDs against workspace-images.ids;
#    copy the whole directory INCLUDING certs/ (same CA -> clients need no re-trust); set HOST_IP/DATA_ROOT; repeat 3-7.
```

## 8. Validation checklist (paste the output into the review session)

```bash
. ./.env; CA=certs/root.crt
docker compose ps
docker compose config --images
docker info | grep -i 'storage driver'
docker stats --no-stream $(docker compose ps -q)

# TLS chain must verify against OUR root (no -k anywhere)
echo | openssl s_client -connect $HOST_IP:$GITEA_PORT -CAfile $CA 2>/dev/null | grep 'Verify return code'
curl -s --cacert $CA -o /dev/null -w 'gitea   %{http_code}\n' https://$HOST_IP:$GITEA_PORT/api/healthz
curl -s --cacert $CA -o /dev/null -w 'outline %{http_code}\n' https://$HOST_IP:$OUTLINE_PORT/_health
curl -s --cacert $CA -o /dev/null -w 'oidc    %{http_code} -> %{redirect_url}\n' https://$HOST_IP:$OUTLINE_PORT/auth/oidc   # expect 302 to gitea
curl -s --cacert $CA https://$HOST_IP:$VIKUNJA_PORT/api/v1/info | python3 -m json.tool | grep -A14 '"auth"'                 # providers[] non-empty
curl -s --cacert $CA https://$HOST_IP:$GITEA_PORT/.well-known/openid-configuration | python3 -m json.tool | grep -E 'issuer|_endpoint'
curl -s --cacert $CA -o /dev/null -D - https://$HOST_IP:$GITEA_PORT/v2/ | grep -iE '^HTTP|www-authenticate'   # 401 + Bearer realm

# postgres: roles, databases, extensions
docker exec workspace-postgres psql -U postgres -c '\du' -c '\l'
docker exec workspace-postgres psql -U postgres -d outline -c '\dx'

# containers trust the CA for their server-side hop
docker exec workspace-outline node -e "fetch('https://$HOST_IP:$GITEA_PORT/api/healthz').then(r=>console.log(r.status)).catch(e=>console.log('FAIL',e.cause?.code))"
docker compose logs vikunja | grep -iE 'x509|openid'     # must be empty

docker compose logs --tail=60 gitea outline vikunja caddy
```

Manual checks to report: (a) Outline "Continue with Gitea" — first login creates the workspace? any installation
screen? (b) Vikunja "Log in with Gitea" — user auto-created with the right username/email? (c) attachment upload in
Outline and Vikunja; (d) `git push` over `ssh://git@$HOST_IP:2222` and over https; (e) `docker login $HOST_IP:$GITEA_PORT`
+ push with the CA in `certs.d`; (f) real-time collaborative editing in Outline (websocket through Caddy).

## 9. Verification log — what has been confirmed by running the stack (2026-09-06)

Reference host: Docker 29.6.1, Compose v5.3.0, 8 GB, overlay storage driver, `connected` profile. It is a
desktop-class Docker runtime rather than a native Linux daemon, which matters in three places: `DATA_ROOT` sat
inside the project directory, bind mounts ignored host uids so no `chown` was needed, and Vikunja was moved to
8084 because 8083 was already in use. Everything else is the file in §6.1 unchanged. Findings that depend on a
native Linux daemon are called out in §10 rather than claimed here.

### 9.1 Outline 1.8.0
* Runs as `uid=1001(nodejs)`. Image ships its own `HEALTHCHECK` (`wget /_health`). `/_health` → 200.
* `FILE_STORAGE=local`, `FILE_STORAGE_LOCAL_ROOT_DIR`, `FILE_STORAGE_UPLOAD_MAX_SIZE` accepted (clean boot). Upload itself not exercised.
* Explicit `OIDC_AUTH_URI/TOKEN_URI/USERINFO_URI` accepted; `/auth/oidc` builds the correct authorize URL
  (`response_type=code`, our `redirect_uri`, `scope=openid profile email`, our `client_id`). `auth.config` lists a single provider "Gitea".
* With one provider configured, `/` renders (200) and the frontend immediately starts the OIDC flow. No installation screen appeared before login (post-login behaviour not yet observed).
* **HTTPS is mandatory** (D5): reproduced the 500 over plain http; source at tag v1.8.0 confirms `secure: env.isProduction`. Works behind Caddy (`app.proxy = true`, `X-Forwarded-Proto`). `NODE_EXTRA_CA_CERTS` makes the server-side hop to Gitea succeed (401 without token = TLS fine).
* `PGSSLMODE=disable` and `FORCE_HTTPS=false` accepted (the latter logs one warn line).

### 9.2 Gitea 1.26
* Tag exists; `curl` present in the image (healthcheck healthy); `/api/healthz` → 200.
* `GITEA__cron_0X2E_update_checker__ENABLED=false` lands in `[cron.update_checker]`; `ROOT_URL/DOMAIN/SSH_DOMAIN/SSH_PORT/LFS_START_SERVER/REVERSE_PROXY_TRUSTED_PROXIES` land in `app.ini` as set.
* `gitea admin user create --admin … --must-change-password=false` works.
* Discovery: **`issuer` = `ROOT_URL` without trailing slash**; `scopes_supported` includes `openid profile email groups`; `claims_supported` includes `email`, `email_verified`, `preferred_username`, `groups`. `token_endpoint` is `/login/oauth/access_token`.
* OAuth2 apps via `POST /api/v1/user/applications/oauth2` (`redirect_uris[]`, `confidential_client:true`) and `PATCH …/{id}` work with basic auth. No admin-level endpoint was found in the API.
* Container registry: `GET /v2/` over TLS through Caddy → `401` with `Www-Authenticate: Bearer realm="https://HOST_IP:8082/v2/token"`.

### 9.3 Vikunja 2.3.0
* Env-based provider config works; `/api/v1/info` exposes `auth.openid_connect.providers[]` with `auth_url` taken from discovery, and `auth.local.enabled=false`.
* `VIKUNJA_SERVICE_JWTSECRET` → WARN "deprecated, using service.secret"; renamed to `VIKUNJA_SERVICE_SECRET`, warning gone.
* `PUID/PGID` honoured (process runs as uid 1000). Image is distroless: no `sh`, `ls`, `wget`, and no `HEALTHCHECK` — debug via logs and `docker top` only.
* `VIKUNJA_DATABASE_HOST=postgres:5432` accepted (migrations ran). `SSL_CERT_FILE` honoured.
* **Discovery is attempted 3× at startup, then Vikunja starts with an empty provider list** and never retries. Hence `depends_on: gitea + caddy service_healthy`; if Gitea was unreachable at boot, `docker compose restart vikunja`.

### 9.4 PostgreSQL 16 / Valkey 8.1
* `init.sql` ran on the empty data dir: roles `outline/gitea/vikunja`, databases owned by them, `uuid-ossp 1.1` + `pg_trgm 1.6` in `outline`; psql backtick `\set` expansion under the entrypoint works; `REVOKE CONNECT ON DATABASE a, b, c FROM PUBLIC` accepted and effective (`gitea` → `outline` = permission denied).
* `pg_isready -h 127.0.0.1` healthcheck: healthy ~10 s after start; apps waited correctly.
* `valkey/valkey:8.1-alpine` exists; `valkey-cli ping` works without auth.

### 9.5 Compose
* `deploy.resources.limits.memory` honoured by Compose v5 without swarm (`docker stats` shows the caps).
* `${VAR:?msg}`, `${VAR:-default}` interpolation and `depends_on.condition: service_healthy` work. YAML `!override`/`!reset` worked in the (now retired) Rev 2 per-host override file.

### 9.6 Caddy 2.10.2
* `pki { ca local { root { cert key } } }` with an openssl-generated EC root: intermediate "Workspace Root CA - ECC Intermediate" issued; leaf has `SAN IP:HOST_IP`; `openssl verify` chain → `0 (ok)` against `certs/root.crt`.
* `default_sni` required for bare-IP addresses (see fix 5). Admin API bound to `127.0.0.1:2019` → healthcheck must use the literal IP (fix 4). `servers { protocols h1 h2 }` silences the h3 UDP buffer warning.
* **Stale-intermediate gotcha:** if `${DATA_ROOT}/caddy` already contains a `pki/authorities/local/intermediate.*` from a previous root, Caddy keeps using it and the chain no longer verifies. Wipe the directory when changing the root.
* Reverse proxy passes through Gitea's registry `401`/`Www-Authenticate` untouched; plain http on a TLS port → 400.
* **Name-constrained root works:** Caddy issues its intermediate and leaf from a root carrying
  `nameConstraints=critical,permitted;IP:192.168.1.0/255.255.255.0`; `openssl verify` of the served chain → ok; a test
  leaf for `IP:10.0.0.5` signed by the same key → *verification failed*; one for `IP:192.168.1.50` → OK.
* **Replacing `certs/root.crt` under a running container does not propagate** (file bind mount keeps the deleted inode):
  Outline logged `Ignoring extra certs … bad end line` until restarted.

## 10. Not yet verified / known gaps

* **Browser logins** (a), (b) and post-login behaviour (Outline workspace creation, Vikunja user auto-creation with `ENABLEREGISTRATION=false`, whether Outline links an OIDC login to an existing user with the same email).
* Attachment uploads (c); `git push` over SSH and https (d); `docker login/push` with the CA in `certs.d` (e) — only the registry endpoint was probed.
* **Websockets through Caddy** for Outline's collaborative editing: Caddy proxies upgrades by default; a raw curl probe was inconclusive (400 without a socket.io handshake). Check in a browser (f).
* **Native Linux daemon:** bind-mount ownership (the `chown` in step 3 becomes load-bearing) and the **hairpin** from a container to `HOST_IP:port` over the host bridge. Both are standard Docker behaviour but have not been observed here. If a host blocks the hairpin, the fallback is `extra_hosts` or an internal DNS name pointing at Caddy — do **not** point `AUTHURL` at `http://gitea:3000`, which breaks the issuer match (D7).
* **Managed container UIs.** Some hosts run Compose through a vendor UI rather than the CLI. Confirm there: `deploy.resources.limits` (honoured by Compose v2 generally), `depends_on` conditions, the relative bind mounts `./init.sql`, `./Caddyfile` and `./certs` (these resolve if the project runs from its own folder), uid ownership on the vendor's storage path, and cgroup v1 on older vendor kernels.
* **Gitea Actions in the `isolated` profile:** `ACTIONS_URL=self` semantics; mirroring `actions/*` into a local org; runner and job images must be pre-loaded; the runner host must trust `root.crt`. Untested in either profile.
* Outline's idle RSS (340–520 MB) runs above the earlier 300–500 MB estimate at peak. The 1 G cap holds, but watch it on an 8 GB host under real usage.
* Gitea `REVERSE_PROXY_TRUSTED_PROXIES="*"` is acceptable because `:3000` is not published; tighten to the compose subnet if that changes.

## 11. Reviewer mission

You are validating **Revision 3**. Do not re-litigate D1–D6 unless you find a concrete blocker. Keep the 100 % FOSS
constraint and the requirement that the `isolated` profile make no outbound call at runtime. Prefer verifying against current upstream documentation over recall; where you cannot verify,
say so explicitly. §9 is evidence, §10 is the open list.

1. **Configuration correctness** of every variable, path and CLI flag in §6 for the pinned versions (Outline 1.8.x,
   Gitea 1.26.x, Vikunja 2.3.x, Postgres 16, Valkey 8.1, Caddy 2.10.x). Flag anything renamed, removed or defaulted differently.
2. **Interpret the §8 output** pasted below: unhealthy container, chain not verifying, missing role/db/extension,
   non-200/302 endpoint, wrong `issuer`, empty Vikunja provider list, `x509` errors, bind-mount permission errors.
3. **OIDC flow and trust model** (§4): redirect URIs, issuer exactness, `email` claim for Outline, first-login behaviour,
   whether the hairpin holds on a native Linux daemon, anything that could make a browser or CLI reject the private CA.
4. **Isolation gaps** (§10): Actions runner images and `ACTIONS_URL=self`, any remaining outbound call from any
   container in the `isolated` profile, image transport and ID verification.
5. **Platform fidelity** (§10) — anything that behaves differently under a vendor-managed Compose UI or an older
   kernel — and **hardware balancing** using the real `docker stats` numbers against ~6.5 GB usable.

Format: findings ordered by severity, each with the exact line in §6 to change. Keep it dense.
