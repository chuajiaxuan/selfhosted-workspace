# Self-hosted developer workspace

Git hosting with a package registry and CI, a wiki, and task tracking — behind **one login** and
**one private CA**, on a single small machine. **100 % free and open source.**

Runs in either of two profiles from the same compose file: **isolated**, with no outbound access at runtime,
or **connected**. Sized for roughly 4 cores and 8 GB; the whole stack idles at **~540 MB**.

| Component | Image | Role |
|---|---|---|
| [Caddy](https://caddyserver.com) | `caddy:2.10.2-alpine` | TLS entry point; signs every certificate from your own root CA |
| [Gitea](https://about.gitea.com) | `gitea/gitea:1.26` | git, LFS, package registry, Actions — **and the OIDC provider** |
| [Outline](https://www.getoutline.com) | `outlinewiki/outline:1.8.0` | wiki, local file storage |
| [Vikunja](https://vikunja.io) | `vikunja/vikunja:2.3.0` | tasks / kanban / gantt |
| [PostgreSQL](https://www.postgresql.org) | `postgres:16-alpine` | shared database, one role + database per app |
| [Valkey](https://valkey.io) | `valkey/valkey:8.1-alpine` | Outline queues, pub/sub, collaboration state |

## Design principles

- **Isolation is a setting, not a fork.** One line in `.env` picks the profile. In `isolated` there are no
  outbound calls at runtime: update checks are off, Actions resolve from this instance, and images arrive by
  `docker save` / `docker load` verified by image ID, because digests do not survive that round trip.
  In `connected`, images pull normally and Actions resolve upstream. Mailers are off in both.
- **One identity.** Gitea's built-in OIDC provider authenticates Outline and Vikunja. Users exist only in Gitea.
  No Keycloak, Authelia or Authentik.
- **One private CA.** Caddy terminates TLS for all three apps and signs from a root you generate once, constrained
  to your LAN subnet. Clients trust one certificate; `docker push` and `git` over https work without
  `insecure-registries`. TLS is not optional here: Outline refuses OIDC login over plain HTTP. This holds in both
  profiles, since the services are reached by LAN address and have no publicly resolvable name.
- **Least privilege in the database.** Each app gets its own role and database, created on first boot; nothing
  connects as the superuser.
- **No secrets in this repository.** Every sensitive value is a `${VAR}` read from an untracked `.env`.

## Quick start

```bash
git clone <this repo> && cd <this repo>
cp env.example .env && chmod 600 .env
# set DEPLOYMENT_PROFILE, HOST_IP, DATA_ROOT and TZ, then generate the secrets
```

Then follow the runbook in **[DESIGN.md](DESIGN.md) §7** — it covers
generating the root CA, creating the data directories, bootstrapping the Gitea admin, registering the two OAuth2
clients, and distributing the CA to client machines.

## Documentation

[DESIGN.md](DESIGN.md) is the single source of truth: goals and
constraints, every design decision with its reasoning, the network and trust model, all four files reproduced
verbatim, the deployment runbook, a validation checklist, and an explicit list of what has been verified by
running the stack versus what is still assumed.

## Secrets and per-cluster state

`.env`, `certs/` and the runtime data directory are excluded by [.gitignore](.gitignore) and must never be
committed. To reuse this repository across several clusters while keeping their secrets, encrypt them per cluster
with [age](https://github.com/FiloSottile/age) and commit only the ciphertext — see §5.1 of the design document.

## Status

Verified end to end on a reference host: TLS chain, OIDC plumbing, database provisioning and health endpoints all
confirmed by running the stack. Browser logins, attachment uploads and registry pushes are not yet exercised.
§9 of the design document records exactly what was observed and §10 lists every open item.

## License

MIT — see [LICENSE](LICENSE).
