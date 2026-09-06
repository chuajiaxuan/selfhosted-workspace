# Self-hosted developer workspace

This stack gives a small team a git server, a wiki and a task tracker. The git server also
has a package registry and a CI function. A user logs in one time and can then use all
three applications. One private CA gives the TLS certificates. All of the software is free
and open source.

The stack operates in two profiles. The **isolated** profile makes no external connection.
The **connected** profile permits external connections. One compose file gives both
profiles. The stack needs approximately 4 processor cores and 8 GB of memory. When the
stack is idle, it uses approximately 540 MB.

| Component | Image | Function |
|---|---|---|
| [Caddy](https://caddyserver.com) | `caddy:2.10.2-alpine` | Receives each HTTP request. Makes the TLS certificates from your root CA. |
| [Gitea](https://about.gitea.com) | `gitea/gitea:1.26` | Gives git, LFS, the package registry, Actions and the OIDC provider. |
| [Outline](https://www.getoutline.com) | `outlinewiki/outline:1.8.0` | Gives the wiki. Keeps the files on a local disk. |
| [Vikunja](https://vikunja.io) | `vikunja/vikunja:2.3.0` | Gives the tasks, the kanban boards and the gantt charts. |
| [PostgreSQL](https://www.postgresql.org) | `postgres:16-alpine` | Gives the database. Each application has one role and one database. |
| [Valkey](https://valkey.io) | `valkey/valkey:8.1-alpine` | Gives the queues, the messages and the collaboration data for Outline. |

## Design rules

- **The profile is a setting, not a different version.** One line in the .env file selects
  the profile. In the isolated profile the stack makes no external connection. Update
  checks are off. Actions come from this Gitea server. You move the images with the
  commands `docker save` and `docker load`, then examine each image by its image ID.
  A digest does not stay correct after these two commands. In the connected profile,
  Docker pulls the images and Actions can come from an external server. The mail function
  is off in both profiles.
- **One identity provider.** Gitea has an OIDC provider. Outline and Vikunja use it. You
  make all user accounts in Gitea. This stack does not include Keycloak, Authelia or
  Authentik.
- **One private CA.** Caddy gives TLS to the three applications. You make the root
  certificate one time. A name constraint limits the root certificate to your local
  network. Each client trusts this one certificate. Then the commands `docker push` and
  `git` operate with HTTPS and do not need the option insecure-registries. TLS is
  necessary, because Outline refuses an OIDC login on an HTTP connection. Both profiles
  use a private CA, because the applications have no public name.
- **Minimum permissions in the database.** Each application has its own role and its own
  database. PostgreSQL makes them at the first start. No application connects as the
  superuser.
- **No secret values in this repository.** Each secret is a variable. The compose file
  reads the variables from the .env file, and that file stays on your machine.

## Procedure to start

```bash
git clone <this repository>
cd <the new directory>
cp env.example .env
chmod 600 .env
```

Write your values in the .env file. Set DEPLOYMENT_PROFILE, HOST_IP, DATA_ROOT and TZ.
Then make the secret values. Then do the steps in section 7 of [DESIGN.md](DESIGN.md).
That section has these procedures:

1. Make the root CA.
2. Make the data directories.
3. Make the first Gitea administrator.
4. Make the two OAuth2 clients.
5. Give the root certificate to each client machine.

## Documentation

[DESIGN.md](DESIGN.md) is the primary document. It has these parts:

- The goals and the limits.
- Each design decision and its reason.
- The network and trust model.
- The four configuration files.
- The deployment runbook and a test list.
- A list of the verified items and a list of the open items.

## Secret values and data

The .gitignore file excludes the .env file, the certs directory and the data directory.
Do not commit these files.

To use this repository for more than one installation, encrypt the secret values of each
installation with [age](https://github.com/FiloSottile/age). Commit only the encrypted
files. Section 5.1 of the design document gives the commands.

## Condition of this stack

A test host ran the full stack. These items are verified: the TLS chain, the OIDC
configuration, the database roles and databases, and the health addresses. These items are
not verified: a login from a browser, a file upload, and a push to the container registry.
Section 9 of the design document lists each verified item. Section 10 lists each open item.

## License

MIT. Refer to the [LICENSE](LICENSE) file.
