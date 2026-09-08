# Self-Hosted Developer Workspace — Design & Source of Truth (Revision 3)

> **The function of DESIGN.md.** This document is the primary reference for the file
> `docker-compose.yml` in this directory. It contains these items:
>
> * The function of the stack.
> * Each design decision and its reason.
> * A list of the verified items and a list of the items that are not verified.
> * The deployment runbook.
> * The test list.
>
> To get a review of the stack, start a new session and give this full document to the
> reviewer. Then run the commands in section 8 and give the output to the reviewer.
>
> Section 6 contains the four configuration files. A tool copies them from the disk.
> WARNING: Do not edit the file contents in section 6. Edit the files on the disk, then
> make this document again.
>
> Revision 1 had many single-function services with Nexus and Garage. Revision 2 made Gitea
> the identity provider, removed Garage and Nexus, and added one database role for each
> application. Revision 3 (2026-09-06) adds TLS with Caddy and a private CA, sends all HTTP
> traffic through Caddy, and corrects three configuration errors. This repository starts at
> revision 3.

## 1. The function of the stack and its limits

This stack gives a small team a developer workspace and a documentation system. It has a git
server, a package registry, a CI function, a wiki and a task tracker. A user logs in one time
and can then use all three applications.

The stack has these limits:

* **All of the software is free and open source.** This stack does not use a "community
  edition" program that has a limit on its use.
* **There are two deployment profiles and one compose file.** The `isolated` profile is the
  default. In this profile the stack makes no external connection. You move the images with
  the commands `docker save` and `docker load`. Gitea Actions come from this Gitea server.
  Update checks are off. In the `connected` profile the host has external access. Docker
  pulls the images and Actions can come from an external server. The profile is one line in
  the .env file and controls two variables. Refer to section 1.1. All other conditions are
  the same, and this includes TLS and the identity provider. In both profiles a user
  connects to a local network address. The applications have no public name.
* **The host.** Use an x86-64 machine with approximately 4 processor cores and 8 GB of
  memory. The machine must have Docker with Compose version 2. A small server, a virtual
  machine, a container host or a storage appliance is satisfactory. Keep 1 to 1.5 GB of
  memory for the operating system and its management software. Thus the containers can use
  approximately 6.5 GB.
* **The storage driver.** The command `docker info` must show an overlay storage driver.
  WARNING: Do not use the driver `vfs`. Its performance is not sufficient.
* **The team is small.** Performance for each megabyte of memory is more important than the
  quantity of servers.

### 1.1 Deployment profiles

| Variable in `.env` | `isolated` (the default) | `connected` |
|---|---|---|
| `ACTIONS_URL` | `self`. The line `uses: actions/checkout@v4` becomes `<ROOT_URL>/actions/checkout`. First copy each action into a local organization with the name `actions`. | `github`. Each action comes from the external server. |
| `UPDATE_CHECKS` | `false`. The update check in Gitea and the update check in Outline are off. | `true` |
| The images | Run `docker save` on a build host. Run `docker load` on the target host. Then examine each image ID. Refer to section 7, step 9. | Run `docker compose pull` on the target host. |

The variable `DEPLOYMENT_PROFILE` is a label for the operator. The compose file reads only
the two variables below it. Use the `connected` profile while you examine the stack. Then
change to the `isolated` profile for the operational installation. No other value changes.

## 2. Decisions and their reasons

| # | Decision | Reason | Condition |
|---|---|---|---|
| D1 | **Gitea is the only identity provider.** It has an OAuth2 and OIDC provider. Outline and Vikunja use it. Local login in Vikunja is off. Self-registration is off in all three applications. | There is one list of users. Keycloak and Authelia are not necessary. Each of those programs needs more than 300 MB of memory. Each is also one more program to back up. | Verified: the discovery file, the scopes and the claims. Refer to section 9.2. A login from a browser is not verified. Refer to section 10. |
| D2 | **The package registry in Gitea replaces Nexus.** | The image `sonatype/nexus3` is a "Community Edition" and has limits on its use from version 3.77. The open-source part supports only Maven, raw and APT. Nexus also needs approximately 2.7 GB of memory. Its primary function is a proxy to an external registry, and an isolated host cannot use that function. | The address `/v2/` gives a reply on a TLS connection. Refer to section 9.2. A `docker push` command is not verified. |
| D3 | **Outline keeps the attachments on a local disk.** The value is `FILE_STORAGE=local`. This stack does not include Garage or S3. | Garage needed a `garage.toml` file, a manual procedure to make the layout, the key and the bucket, and a CORS configuration for the browser. Only one application used it. | Outline accepted the configuration at the start. A file upload is not verified. |
| D4 | **Each application has one PostgreSQL role and one database.** The file `init.sql` makes them one time. No application connects as the superuser. The file also runs `REVOKE CONNECT … FROM PUBLIC`. | Each application has the minimum permissions. You can change one password and the other applications continue to operate. | Verified. Refer to section 9.4. |
| D5 | **Caddy gives TLS to the three applications.** Caddy signs the certificates with your root CA. The file `certs/root.crt` has a life of 10 years. You make it one time with openssl. The application containers have no open HTTP port. Only Caddy and the Gitea SSH port are open. | TLS is necessary. With `NODE_ENV=production`, Outline 1.8 sets the Secure flag on the OAuth state cookie. The file is `server/utils/passport.ts` and the value is `secure: env.isProduction`. The variables `FORCE_HTTPS` and `URL` do not change this condition. On an HTTP connection, koa gives the message "Cannot send secure cookie over unencrypted connection" and the error 500 at `/auth/oidc`. Outline thus needs TLS. One CA for the three applications then has three more advantages. Each client trusts one certificate. The commands `docker push` and `git` operate with HTTPS and do not need the option `insecure-registries`. No password and no token goes through the network as plain text. | Verified on the reference host. Refer to section 9.6. |
| D6 | **You make the root CA, not Caddy.** Caddy signs the intermediate certificate and the server certificates with your key. The configuration is `pki { ca local { root { cert/key } } }`. The root certificate has a name constraint. The constraint permits only your local network. | Caddy can make its own root certificate with the command `tls internal`. But Caddy keeps that certificate in `DATA_ROOT/caddy` with mode 600 and the owner root. Vikunja operates as user 1000 and cannot read it. Vikunja needs it for its OIDC requests. Caddy also makes that certificate only at the first start, and `depends_on` cannot wait for it. Your `certs/root.crt` is a usual file with mode 644. You can do a read-only bind mount of the file into Outline and Vikunja. You can also back it up and give it to a client. The name constraint has one more advantage. If a person gets your key, that person cannot make a certificate for a public address. | Verified, and a negative test is included. Refer to section 9.6. |
| D7 | **Outline and Vikunja use the public address for their OIDC requests.** They connect to `https://HOST_IP:GITEA_PORT`. They do not connect to `http://gitea:3000`. | Vikunja compares `AUTHURL` with the issuer in the discovery file. The two values must agree. Gitea gives its `ROOT_URL` as the issuer. Thus the two containers trust `certs/root.crt`. They use `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE`. They connect to the open port on the host. | Verified on the reference host. Refer to section 9.6. A native Linux daemon does the same, but this is not verified. Refer to section 10. |
| D8 | **The host ports are variables.** They are `OUTLINE_PORT`, `GITEA_PORT` and `VIKUNJA_PORT`. The default values are 8081, 8082 and 8083. The port mappings, all addresses and the Caddyfile use these variables. | A different program used port 8083 on the reference host. One line in the .env file moves an application to a different port. An override file is not necessary. | Verified. Vikunja moved to port 8084. |
| D9 | **Operational rules.** Use a version tag that does not change. Examine each image that you move, and use the image ID. Set a memory limit for each service. Rotate the JSON log files. Use the variable `${DATA_ROOT}`. Let the profile control the external requests with `UPDATE_CHECKS` and `ACTIONS_URL`. | The result is a repeatable transport procedure and a known memory quantity on a host with 8 GB. One file operates in the two profiles. | The tags are correct. The variable name escape is verified. Refer to section 9.2. |
| D10 | **These programs are not in the stack:** Plane, OpenProject and Focalboard. | The air-gap packages for Plane are commercial. OpenProject is one large program and uses 2.5 to 3.5 GB when it is idle. Focalboard is at the end of its life. | Not applicable. |

### 2.1 Corrections in revision 3

A test of the stack showed each of these errors:

1. The variable `VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_AUTHURL` must not have a slash at the
   end. Gitea 1.26 gives the issuer as `ROOT_URL` without the last slash. Revision 2 had a
   slash, and the comparison in Vikunja failed.
2. The variable `VIKUNJA_SERVICE_JWTSECRET` is obsolete. Use `VIKUNJA_SERVICE_SECRET`.
   Vikunja 2 writes a warning in the log for the old name.
3. Outline needs TLS. Refer to decision D5. The value `FORCE_HTTPS=false` stops only the
   redirect from HTTP to HTTPS. It does not remove the Secure flag from the cookie.
4. The Caddy healthcheck must use the address `127.0.0.1:2019`. In the container, the name
   `localhost` first becomes the address `::1`, and the connection then fails.
5. The Caddyfile must have the line `default_sni {$HOST_IP}`. A browser and the command curl
   do not send an SNI value for an IP address. Without this line the TLS connection fails
   with the message "tlsv1 alert internal error".

## 3. The components

| Component | Image | Function | Memory limit | Memory when idle |
|---|---|---|---|---|
| Caddy | `caddy:2.11.4-alpine` | Receives each HTTP request. Signs the certificates. | 128 M | 20 to 60 MB |
| PostgreSQL | `postgres:18.6-alpine` | The database. One role and one database for each application. | 512 M | approximately 50 MB |
| Valkey | `valkey/valkey:9.1.2-alpine` | The queues, the messages and the collaboration data for Outline. It writes no data to a disk. | 128 M | approximately 20 MB |
| Gitea | `gitea/gitea:1.27.3` | git, LFS, the packages, Actions and the **OIDC provider**. | 1 G | 130 to 190 MB |
| Outline | `outlinewiki/outline:1.10.0` | The wiki. It keeps the files on a local disk and uses Gitea for the login. | 1 G | 310 MB. It uses more memory immediately after the migrations. |
| Vikunja | `vikunja/vikunja:2.6.0` | The tasks, the kanban boards and the gantt charts. It uses Gitea for the login. | 256 M | approximately 70 MB |

When the stack is idle, it uses approximately **690 MB**. The sum of the memory limits is
3 GB. The budget is approximately 6.5 GB. Thus there is sufficient memory. These quantities
do not show a necessity to adjust the PostgreSQL configuration.

### 3.1 The version policy

Use a full version tag for each image. WARNING: Do not use a tag such as `16-alpine` or
`1.26`. A tag of that type moves to a new image, and the installation is then not
repeatable. The stack had three tags of that type before 2026-09-08.

These rules apply to specified components:

* **Valkey.** Use version 9.1.2 or a later version. Versions 9.1.0 and 9.1.1 have two
  faults. A blocking command can stop a client permanently, and a key can keep its value
  after its time limit. Outline uses blocking commands for its job queues.
* **Caddy.** Do not use version 2.11.1. A configuration reload in a container fails in that
  version. WARNING: From version 2.11, Caddy does not start if the root certificate has less
  than 7 days of validity. Examine the certificate before an upgrade:
  `openssl x509 -in certs/root.crt -noout -enddate`
* **PostgreSQL.** This stack uses version 18. WARNING: A move from version 16 to version 18
  is not a change of the tag. Refer to section 7.1 for the procedure and for the mount path.

## 4. The network and the trust model

```
 A browser, a git client or a docker client      (each machine trusts certs/root.crt one time)
        │ https://HOST_IP:8081  https://HOST_IP:8082  https://HOST_IP:8083   ssh://git@HOST_IP:2222
        ▼                                                                             │
 ┌── caddy ──────────────────────────────────────────────────────────┐                │
 │  server certificate (SAN = HOST_IP)                               │                │
 │        ← intermediate certificate ← certs/root.crt                │                │
 └───┬───────────────────────┬───────────────────────┬───────────────┘                │
     ▼ outline:3000          ▼ gitea:3000            ▼ vikunja:3456  ◄────────────────┘ gitea:22
     │                       ▲        ▲              │
     │ token, userinfo       │        │  discovery, token, userinfo
     └── https://HOST_IP:8082┘        └── https://HOST_IP:8082
                                          (through the host port; trusts /certs/root.crt)
     postgres:5432 (roles outline, gitea, vikunja)      valkey:6379 (only outline)
```

* **The trust.** Each client machine trusts `certs/root.crt`. Do this one time for each
  machine. Refer to section 7, step 8. Outline trusts the certificate with
  `NODE_EXTRA_CA_CERTS`. Vikunja trusts it with `SSL_CERT_FILE`. The Go runtime replaces
  the system certificate list with this one file. This is satisfactory, because Vikunja
  connects only to Gitea. Gitea makes no external TLS connection.
* **The words "online root".** The private key of the root CA is on the server, in the Caddy
  container. A CA of this type has the name "online root". This name is a term from public
  key infrastructure. It does not refer to internet access. The automatic CA in Caddy is
  also an online root and also has a life of 10 years. A different method is the "offline
  root". For that method you keep the root key on removable media. You then give Caddy only
  the root certificate and an intermediate certificate and key, with `pki > ca >
  intermediate`. Caddy permits this method, but this stack does not use it. With that
  method you must make the intermediate certificate again before it expires. If you forget,
  the stack stops.
* **The life of the CA.** Keep `certs/root.key` in the compose directory with mode 600. Caddy
  makes an intermediate certificate with a life of 7 days. Caddy makes a server certificate
  with a life of 12 hours. Caddy makes these certificates again automatically. Nothing
  expires for 10 years.
* **To replace the root CA**, do these steps in this sequence:
  1. Put the new files in the `certs` directory.
  2. Delete the contents of `${DATA_ROOT}/caddy`. WARNING: Do not omit this step. Caddy keeps
     the old intermediate certificate, and then the TLS chain is not correct.
  3. Run `docker compose up -d`.
  4. Run `docker compose restart outline vikunja`. WARNING: Do not omit this step. A file
     bind mount keeps the old file, and Outline then gives the error "bad end line".
  5. Give the new root certificate to each client machine.
* **The effect of a lost key.** The name constraint permits certificates only for addresses
  in your local network. Thus a person with your key cannot make a certificate for a public
  address. OpenSSL, Chrome and Firefox obey a name constraint on a root certificate that a
  user adds. The behaviour of the Apple verifier is not confirmed. Thus the name constraint
  is an additional protection, not a full protection. On the server, only the root user can
  read the key.
* **To change `HOST_IP`**, for example to move the stack to a different host, you do not
  change the CA. Caddy makes the server certificates again. Make the two OAuth2 redirect
  addresses in Gitea again. Refer to section 7, step 6. WARNING: That procedure makes a new
  client secret for each application. Write the two new secrets in the .env file, then run
  `docker compose up -d`. Then tell the users the new address.
* **There is no HTTP service.** Caddy gives the error 400 for an HTTP request to a TLS port.
  The SSH port is the only port without TLS.

## 5. The directory layout

```
selfhosted-workspace/
├── DESIGN.md              This document. The primary reference.
├── README.md              The first page of the repository.
├── LICENSE                The MIT license.
├── docker-compose.yml     The stack. Section 6.1 shows this file.
├── Caddyfile              The TLS and proxy configuration. Section 6.2 shows this file.
├── env.example → .env     The host values and the secret values. Mode 600. Section 6.3.
├── init.sql               The database roles and databases. Section 6.4 shows this file.
├── certs/root.crt  0644   Give this file to each client machine.
├── certs/root.key  0600   Keep this file in this directory.
├── .gitignore             This file excludes each private file. Refer to section 5.1.
└── ${DATA_ROOT}/{postgres,gitea,outline,vikunja/files,caddy}   The data. It is not in the repository.
```

### 5.1 The public files and the private files

Use this table when you keep this directory in a public git repository.

| Condition | Files | Reason |
|---|---|---|
| Commit these files | `docker-compose.yml`, `Caddyfile`, `init.sql`, `env.example`, `DESIGN.md`, `README.md`, `LICENSE` | These files have no secret values. |
| Do not commit | `.env` | This file has each database password, the Outline secret values, the Vikunja secret values, the Gitea administrator password and the OIDC client secret values. |
| Do not commit | `certs/root.key` | This file is the private key of the CA. A person with this key can be a false server for each client that trusts the root certificate. |
| Do not commit | `certs/root.crt` | This file is not secret, because you give it to each client. But it is different for each installation. Keep it with the secret values of that installation. |
| Do not commit | `${DATA_ROOT}/` | This directory has the databases, the repositories, the SSH host keys and the file `gitea/conf/app.ini`. That file has the JWT secret values and the LFS secret values. |
| Do not commit | The local notes, `*.tgz` and `*.ids` | The notes contain the address of one installation. The archives contain the images. |

The compose file has no secret values. Each secret is a `${VAR}` value, and the compose file
reads it from the .env file. The values `HOST_IP` and `DATA_ROOT` are not secret, but they
are different for each installation. Thus they are also in the .env file.

**To keep the secret values of more than one installation**, encrypt them with
[age](https://github.com/FiloSottile/age). This program is free, is one file and needs no
external access. Commit only the encrypted files.

```bash
# Install age with the package manager of your system.
# Make one identity for each person. Do not make one identity for each installation.
age-keygen -o ~/.config/age/keys.txt   # This command shows a public key: age1…
                                       # Keep keys.txt in your password manager.
mkdir -p clusters/<name>
age -r age1…  -o clusters/<name>/env.age       .env
age -r age1…  -o clusters/<name>/root.key.age  certs/root.key
cp certs/root.crt clusters/<name>/root.crt     # This file is public. Do not encrypt it.

# On a different machine, after you clone the repository:
age -d -i ~/.config/age/keys.txt clusters/<name>/env.age      > .env            && chmod 600 .env
age -d -i ~/.config/age/keys.txt clusters/<name>/root.key.age > certs/root.key  && chmod 600 certs/root.key
cp clusters/<name>/root.crt certs/root.crt
```

Obey these four rules:

1. Keep the age identity file outside git. Put it in a password manager or on a USB device.
2. Encrypt the .env file again after each change. A new OIDC secret and a new password are
   changes.
3. For an isolated host, copy the `age` program to that host. As an alternative, decrypt the
   files on your own machine and then copy the .env file and the `certs` directory.
4. WARNING: A value in a git commit stays in the git history. If you commit a secret value,
   write the history again and change that value. A scanner such as
   [gitleaks](https://github.com/gitleaks/gitleaks) finds a secret value before you commit
   it. For encrypted files that show the key names,
   [SOPS](https://github.com/getsops/sops) with age is an alternative to age alone.

## 6. The configuration files

### 6.1 `docker-compose.yml`

```yaml
# Self-hosted developer workspace. Revision 3.
#
# This stack has five applications. Caddy gives TLS to the three web applications.
# Outline is the wiki. Gitea gives git, packages, actions and OIDC. Vikunja gives tasks.
# All three applications use one PostgreSQL server and one Valkey server.
#
# These files are in the same directory:
#   .env             Copy env.example, then write your values in it.
#   init.sql         PostgreSQL runs this file one time.
#   Caddyfile        The TLS and proxy configuration.
#   certs/root.crt   The root certificate. Give this file to each client.
#   certs/root.key   The root private key. Make this key one time. Refer to the runbook.
#
# AUTHENTICATION
# Gitea is the only identity provider. Outline and Vikunja use the OIDC provider in Gitea.
# You make all user accounts in Gitea.
#
# NETWORK
#   A browser connects to https://HOST_IP:8081, 8082 or 8083. Caddy receives the request.
#   Caddy sends the request to outline:3000, gitea:3000 or vikunja:3456.
#   A git client connects to ssh://git@HOST_IP:2222. Gitea receives the request on port 22.
#   The SSH connection does not go through Caddy.
#   Only Caddy and the Gitea SSH port are open on the host. The other containers are
#   available only on the compose network.
#   Outline and Vikunja also connect to https://HOST_IP:8082 for OIDC. They use the same
#   address as a browser. Thus the issuer value is always the same. These two containers
#   trust the file certs/root.crt for this connection.
#
# DEPLOYMENT PROFILES
# Set DEPLOYMENT_PROFILE in the .env file. The profile controls two variables.
#   isolated    The host has no external access. You move the images with the commands
#               `docker save` and `docker load`. Actions come from this Gitea server.
#               Update checks are off. This profile is the default.
#   connected   The host has external access. Docker pulls the images. Actions can come
#               from an external server.
# The two profiles are the same in all other conditions. Both profiles use TLS. Neither
# profile has a public name, thus both profiles use a private CA.
#
# RULES
#   * All data is in the directory ${DATA_ROOT}. Use an absolute path on the host.
#     Some Docker interfaces permit bind mounts only from specified parent directories.
#     Make sure that your container runtime can do a bind mount from your path.
#   * Each image is a variable. Thus this file operates in the two profiles.
#     Use a version tag that does not change.
#   * WARNING: A digest does not stay correct after `docker save` and `docker load`.
#     Examine each image that you move. Use the image ID for this check.
#     Command: docker image inspect --format '{{.Id}}'
#   * The secret values are only in .env and in certs/root.key. Set mode 600 on both files.
#   * This stack does not include Garage. Outline keeps its files on a local disk from
#     version 0.72.
#   * This stack does not include Nexus. The package registry in Gitea keeps the artifacts.
#     An isolated host cannot use the proxy function in Nexus.

name: workspace

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:

  # ---------------------------------------------------------------------------
  # Caddy is the only HTTP entry point. Caddy uses your root CA and makes the TLS
  # certificates.
  # ---------------------------------------------------------------------------
  caddy:
    image: ${CADDY_IMAGE:-caddy:2.11.4-alpine}
    container_name: workspace-caddy
    restart: unless-stopped
    ports:
      - "${OUTLINE_PORT:-8081}:${OUTLINE_PORT:-8081}"
      - "${GITEA_PORT:-8082}:${GITEA_PORT:-8082}"
      - "${VIKUNJA_PORT:-8083}:${VIKUNJA_PORT:-8083}"
    environment:
      # The Caddyfile reads these values. In the Caddyfile they have the form {$VAR}.
      HOST_IP: ${HOST_IP:?set HOST_IP in .env}
      OUTLINE_PORT: ${OUTLINE_PORT:-8081}
      GITEA_PORT: ${GITEA_PORT:-8082}
      VIKUNJA_PORT: ${VIKUNJA_PORT:-8083}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      # The root CA. Caddy uses this key to sign an intermediate certificate and the
      # server certificates. These certificates have a short life.
      - ./certs:/certs:ro
      # The intermediate certificate, the server certificates and the locks.
      # You can delete this directory. Caddy makes these certificates again.
      - ${DATA_ROOT:-/opt/workspace}/caddy:/data
    healthcheck:
      # This test shows that Caddy read the configuration and operates correctly.
      # The admin API listens only on 127.0.0.1 in the container.
      # WARNING: Use the IP address 127.0.0.1. In the container, the name "localhost"
      # first becomes the address ::1. Then the test fails.
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
  # The shared servers: the database and the cache.
  # ---------------------------------------------------------------------------
  postgres:
    image: ${POSTGRES_IMAGE:-postgres:18.6-alpine}
    container_name: workspace-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?copy env.example to .env and fill it in}
      # The file init.sql reads these values at the first start. It makes one role
      # for each application.
      OUTLINE_DB_PASSWORD: ${OUTLINE_DB_PASSWORD}
      GITEA_DB_PASSWORD: ${GITEA_DB_PASSWORD}
      VIKUNJA_DB_PASSWORD: ${VIKUNJA_DB_PASSWORD}
    volumes:
      # WARNING: Mount the directory at /var/lib/postgresql, not at
      # /var/lib/postgresql/data. From version 18, the image keeps its data in
      # /var/lib/postgresql/18/docker. The image does not start if a directory is
      # mounted at /var/lib/postgresql/data. An empty directory also stops the start.
      - ${DATA_ROOT:-/opt/workspace}/postgres:/var/lib/postgresql
      # PostgreSQL runs this file only when the data directory is empty. The file
      # makes the roles and the databases.
      - ./init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro
    healthcheck:
      # The option -h 127.0.0.1 makes pg_isready use TCP.
      # WARNING: Do not remove this option. Without it, pg_isready uses the UNIX socket.
      # That socket is available while PostgreSQL runs the initialization files.
      # Then depends_on starts the applications too soon and they cannot connect.
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
    image: ${VALKEY_IMAGE:-valkey/valkey:9.1.2-alpine}
    container_name: workspace-valkey
    restart: unless-stopped
    # Outline uses Valkey for the job queues, for the websocket messages and for the
    # collaboration data. Valkey does not write this data to a disk. The data is not
    # necessary after a restart.
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
  # Gitea gives git, the package registry, Actions and the OIDC provider.
  # ---------------------------------------------------------------------------
  gitea:
    image: ${GITEA_IMAGE:-gitea/gitea:1.27.3}
    container_name: workspace-gitea
    restart: unless-stopped
    ports:
      - "2222:22"                                  # Only SSH is open here. Caddy gives HTTP.
    volumes:
      # This directory has the repositories, the LFS objects, the SSH host keys and
      # the file app.ini. The file app.ini also has the JWT secret values.
      - ${DATA_ROOT:-/opt/workspace}/gitea:/data
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      # The database. The file init.sql makes this role.
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: postgres:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: ${GITEA_DB_PASSWORD}
      GITEA__database__SSL_MODE: disable
      # ROOT_URL controls four values: the browser address, the clone address, the
      # registry name and the OIDC issuer.
      # NOTE: In Gitea 1.26 the OIDC issuer is ROOT_URL without the last slash.
      GITEA__server__ROOT_URL: https://${HOST_IP:?}:${GITEA_PORT:-8082}/
      GITEA__server__DOMAIN: ${HOST_IP}
      GITEA__server__SSH_DOMAIN: ${HOST_IP}
      GITEA__server__SSH_PORT: "2222"
      GITEA__server__LFS_START_SERVER: "true"
      # Port 3000 is not open on the host. Only Caddy can connect to it. Thus Gitea can
      # trust the header X-Forwarded-For and record the client address in the log.
      GITEA__security__REVERSE_PROXY_TRUSTED_PROXIES: "*"
      # These options make an unattended and closed installation.
      GITEA__security__INSTALL_LOCK: "true"          # No web installer. Make the admin
                                                     # with `gitea admin user create`.
      GITEA__service__DISABLE_REGISTRATION: "true"   # Only an admin makes a user.
      GITEA__repository__DEFAULT_BRANCH: main
      GITEA__mailer__ENABLED: "false"
      # A section name with a "." becomes _0X2E_ in a variable name. This variable
      # goes to the section [cron.update_checker].
      GITEA__cron_0X2E_update_checker__ENABLED: "${UPDATE_CHECKS:-false}"   # isolated: no external request
      # These options control the functions.
      GITEA__oauth2__ENABLED: "true"                 # The OIDC provider for Outline and Vikunja.
      # Gitea 1.27 adds a built-in OAuth2 application for its own desktop client.
      # This installation does not use that client. An empty value removes it.
      GITEA__oauth2__DEFAULT_APPLICATIONS: ""

      GITEA__packages__ENABLED: "true"               # The registry for container, Maven,
                                                     # npm, PyPI and other packages.
      GITEA__actions__ENABLED: "true"
      # With the value "self", the line `uses: actions/checkout@v4` becomes the address
      # <ROOT_URL>/actions/checkout. Before you start a workflow, copy each action that
      # you use into a local organization with the name "actions".
      # With the value "github", each action comes from the external server.
      GITEA__actions__DEFAULT_ACTIONS_URL: ${ACTIONS_URL:-self}
      # Gitea 1.27 adds instance-wide workflow directories and enables them. After an
      # administrator registers a source repository, its workflows operate on each
      # repository. An empty value keeps each repository independent.
      GITEA__actions__SCOPED_WORKFLOW_DIRS: ""
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
  # Outline is the wiki. It keeps its files on a local disk. Gitea gives the identity.
  # ---------------------------------------------------------------------------
  outline:
    image: ${OUTLINE_IMAGE:-outlinewiki/outline:1.10.0}
    container_name: workspace-outline
    restart: unless-stopped
    volumes:
      # The attachments and the images. The container operates as user 1001.
      # On the host, set the owner of this directory to 1001:1001.
      - ${DATA_ROOT:-/opt/workspace}/outline:/var/lib/outline/data
      # Outline trusts this certificate. Outline uses it for the token request and
      # the userinfo request to https://HOST_IP:GITEA_PORT.
      - ./certs/root.crt:/certs/root.crt:ro
    environment:
      NODE_ENV: production
      NODE_EXTRA_CA_CERTS: /certs/root.crt
      # The address for the browser. It must agree with the address that a user types.
      URL: https://${HOST_IP}:${OUTLINE_PORT:-8081}
      PORT: "3000"
      # Outline trusts the header X-Forwarded-Proto from Caddy.
      # WARNING: TLS is necessary. With NODE_ENV=production, Outline sets the Secure flag
      # on the OAuth state cookie. The login fails on an HTTP connection.
      FORCE_HTTPS: "false"               # There is no HTTP listener, thus this value
                                         # has no effect.
      ENABLE_UPDATES: "${UPDATE_CHECKS:-false}"   # isolated: no update checks
      WEB_CONCURRENCY: "1"               # One process is sufficient for a small team.
      LOG_LEVEL: info
      DEFAULT_LANGUAGE: en_US
      SECRET_KEY: ${OUTLINE_SECRET_KEY}         # Use 64 hexadecimal characters.
      UTILS_SECRET: ${OUTLINE_UTILS_SECRET}     # Use 64 hexadecimal characters.
      # The database and the cache.
      DATABASE_URL: postgres://outline:${OUTLINE_DB_PASSWORD}@postgres:5432/outline
      PGSSLMODE: disable                 # Without this value, Outline makes a TLS
                                         # connection to PostgreSQL.
      REDIS_URL: redis://valkey:6379
      # The file storage. Outline uses a local disk and does not use S3.
      FILE_STORAGE: local
      FILE_STORAGE_LOCAL_ROOT_DIR: /var/lib/outline/data
      FILE_STORAGE_UPLOAD_MAX_SIZE: "262144000"   # 250 MB.
      # The authentication. Outline uses the OIDC provider in Gitea.
      # First, make the application in Gitea. Use the admin user, then Settings, then
      # Applications. As an alternative, use the API.
      #   Redirect URI:        https://${HOST_IP}:${OUTLINE_PORT}/auth/oidc.callback
      #   Confidential client: yes
      # Then write the client ID and the client secret in the .env file.
      OIDC_CLIENT_ID: ${OUTLINE_OIDC_CLIENT_ID:-}
      OIDC_CLIENT_SECRET: ${OUTLINE_OIDC_CLIENT_SECRET:-}
      OIDC_AUTH_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/authorize
      OIDC_TOKEN_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/access_token
      OIDC_USERINFO_URI: https://${HOST_IP}:${GITEA_PORT:-8082}/login/oauth/userinfo
      OIDC_USERNAME_CLAIM: preferred_username
      OIDC_DISPLAY_NAME: Gitea
      # WARNING: Keep the scope "email". Outline needs the email claim.
      OIDC_SCOPES: openid profile email
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
  # Vikunja gives the tasks, the kanban boards and the gantt charts. A user can log in
  # only with Gitea. There are no local accounts.
  # ---------------------------------------------------------------------------
  vikunja:
    image: ${VIKUNJA_IMAGE:-vikunja/vikunja:2.6.0}
    container_name: workspace-vikunja
    restart: unless-stopped
    volumes:
      # The task attachments. The container operates as the user in PUID and PGID.
      # On the host, set the owner of this directory to 1000:1000.
      - ${DATA_ROOT:-/opt/workspace}/vikunja/files:/app/vikunja/files
      # Vikunja trusts this certificate. Vikunja uses it for the discovery request, the
      # token request and the userinfo request to https://HOST_IP:GITEA_PORT.
      - ./certs/root.crt:/certs/root.crt:ro
    environment:
      # NOTE: This image has no shell and operates as user 1000. The variables PUID
      # and PGID have no function here. Set the owner of the data directory to
      # 1000:1000 on the host.
      TZ: ${TZ:-UTC}
      # This file replaces the system certificate list for the Go runtime.
      SSL_CERT_FILE: /certs/root.crt
      # Vikunja uses this address for the share links and for CalDAV.
      VIKUNJA_SERVICE_PUBLICURL: https://${HOST_IP}:${VIKUNJA_PORT:-8083}/
      # In Vikunja 2, service.secret replaces service.jwtsecret. The old name is
      # obsolete. Vikunja writes a warning in the log if you use the old name.
      VIKUNJA_SERVICE_SECRET: ${VIKUNJA_JWT_SECRET}
      VIKUNJA_SERVICE_TIMEZONE: ${TZ:-UTC}
      VIKUNJA_SERVICE_ENABLEREGISTRATION: "false"          # A user cannot make a local account.
      # The authentication. Vikunja uses Gitea with OIDC. Vikunja makes the user account
      # at the first login.
      # First, make the application in Gitea. Use the admin user, then Settings, then
      # Applications. As an alternative, use the API.
      #   Redirect URI:        https://${HOST_IP}:${VIKUNJA_PORT}/auth/openid/gitea
      #                        The last part of the address is the provider key. It is the
      #                        word GITEA below, in small letters.
      #   Confidential client: yes
      # AUTHURL is the OIDC issuer. Vikunja gets the file
      # <AUTHURL>/.well-known/openid-configuration. The issuer in that file must agree
      # with AUTHURL.
      # WARNING: Do not put a slash at the end of AUTHURL. Gitea 1.26 gives the issuer
      # without a slash at the end. If the two values do not agree, the login fails.
      # Set the value below to "true" if you need a local account for an emergency.
      VIKUNJA_AUTH_LOCAL_ENABLED: "false"
      VIKUNJA_AUTH_OPENID_ENABLED: "true"
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_NAME: Gitea
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_AUTHURL: https://${HOST_IP}:${GITEA_PORT:-8082}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_CLIENTID: ${VIKUNJA_OIDC_CLIENT_ID:-}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_CLIENTSECRET: ${VIKUNJA_OIDC_CLIENT_SECRET:-}
      VIKUNJA_AUTH_OPENID_PROVIDERS_GITEA_SCOPE: openid profile email
      # The database. The file init.sql makes this role.
      VIKUNJA_DATABASE_TYPE: postgres
      VIKUNJA_DATABASE_HOST: postgres:5432
      VIKUNJA_DATABASE_DATABASE: vikunja
      VIKUNJA_DATABASE_USER: vikunja
      VIKUNJA_DATABASE_PASSWORD: ${VIKUNJA_DB_PASSWORD}
      VIKUNJA_DATABASE_SSLMODE: disable
      VIKUNJA_MAILER_ENABLED: "false"
      VIKUNJA_FILES_MAXSIZE: 50MB
      # Vikunja keeps its cache in memory. This cache is sufficient for a small team.
      # To use Valkey for the cache, remove the # from the four lines that follow.
      # VIKUNJA_CACHE_ENABLED: "true"
      # VIKUNJA_CACHE_TYPE: redis
      # VIKUNJA_REDIS_ENABLED: "true"
      # VIKUNJA_REDIS_HOST: valkey:6379
    depends_on:
      postgres:
        condition: service_healthy
      gitea:
        condition: service_healthy       # Vikunja gets the discovery file at the start.
      caddy:
        condition: service_healthy       # The request goes through Caddy with TLS.
    deploy:
      resources:
        limits:
          memory: 256M
    logging: *default-logging
```

### 6.2 `Caddyfile`

```caddyfile
# Caddy gives TLS to the three applications. Caddy signs the certificates with your root CA.
# The values {$VAR} come from the environment of the caddy service in docker-compose.yml.
#
# TLS is necessary on a local network for this stack. With NODE_ENV=production, Outline 1.8
# sets the Secure flag on the OAuth state cookie. Then an HTTP login gives the error 500.
# One CA for the three applications has a second advantage. The commands `docker push` and
# `git` operate with HTTPS. You do not need the option insecure-registries.
{
	# The admin API stays in the container. It is not open on the host.
	# The healthcheck in docker-compose.yml uses this API.
	admin localhost:2019
	auto_https disable_redirects   # There is no listener on port 80.
	skip_install_trust             # Do not install the root certificate in the container.
	# A browser and the command curl do not send an SNI value for an IP address.
	# Caddy then gives the certificate for this address.
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
		protocols h1 h2          # HTTP/3 needs UDP ports. Use only TCP.
		# A user types an address without a scheme, for example 192.168.1.50:8081.
		# The browser then makes an HTTP request to a port that gives only HTTPS.
		# Without the wrapper below, the Go library answers with the error 400 and the
		# message "Client sent an HTTP request to an HTTPS server". Caddy cannot change
		# that answer, because it comes before the TLS operation.
		# The wrapper http_redirect examines the first bytes of the connection. For an
		# HTTP request it answers with the code 308 and the same address with https. The
		# port, the path and the query stay the same.
		# WARNING: Keep this sequence. The name tls shows the position of the TLS
		# operation in the chain, and http_redirect must come before it.
		listener_wrappers {
			http_redirect
			tls
		}
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
# Copy this file to .env. Write your values in it. Then set mode 600 on the file.
# Each value is plain text.
# Use only the characters A-Z, a-z and 0-9 in a password. Then the password is correct
# in an address.
# Do not put a comment after a value on the same line.

# --- deployment profile -------------------------------------------------------
# isolated   The host has no external access. You move the images with the commands
#            docker save and docker load. Actions come from this Gitea server. Update
#            checks are off. This profile is the default.
# connected  The host has external access. Docker pulls the images. Actions can come from
#            an external server.
# The profile controls only the two variables below. All other conditions are the same.
# Both profiles use TLS.
DEPLOYMENT_PROFILE=isolated
ACTIONS_URL=self                # isolated: self.  connected: github.
UPDATE_CHECKS=false             # isolated: false.  connected: true.

# --- deployment ---------------------------------------------------------------
# The address that a user types in a browser. Use an IP address or a name on your local
# network. Select this address one time.
# NOTE: If you change this address later, make the two OAuth2 redirect addresses in Gitea
# again. The change does not affect the CA. A client keeps its trust of the root
# certificate.
HOST_IP=192.168.1.50
# The absolute path on the host for all data. Your container runtime must be able to do a
# bind mount from this path. Some Docker interfaces permit bind mounts only from specified
# parent directories.
DATA_ROOT=/opt/workspace
TZ=UTC
# The host ports for Caddy. All three ports use TLS.
# Change a port only if a different program uses it.
OUTLINE_PORT=8081
GITEA_PORT=8082
VIKUNJA_PORT=8083

# --- images -------------------------------------------------------------------
# Use a full version tag. WARNING: Do not use a tag such as "16-alpine" or "1.26".
# Those tags move to a new image and the installation is then not repeatable.
#
# NOTE on Valkey: use 9.1.2 or a later version. Versions 9.1.0 and 9.1.1 have two
# faults. A blocking command can stop a client permanently, and a key can keep its
# value after the time limit. Outline uses blocking commands for its job queues.
#
# NOTE on PostgreSQL: this line stays on version 16. PostgreSQL 16 has support until
# 2028-11-09. Version 18 needs a data migration, not a new tag. Refer to DESIGN.md,
# section 11.
CADDY_IMAGE=caddy:2.11.4-alpine
POSTGRES_IMAGE=postgres:18.6-alpine
VALKEY_IMAGE=valkey/valkey:9.1.2-alpine
GITEA_IMAGE=gitea/gitea:1.27.3
OUTLINE_IMAGE=outlinewiki/outline:1.10.0
VIKUNJA_IMAGE=vikunja/vikunja:2.6.0

# --- secret values ------------------------------------------------------------
# These two commands make the seven secret values. The examples show GNU sed.
# NOTE: BSD sed needs the option -i '' in place of -i.
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

# --- the first Gitea administrator ---------------------------------------------
# The runbook uses these values in the command `gitea admin user create`.
# The compose file does not read them.
GITEA_ADMIN_USER=admin
GITEA_ADMIN_PASSWORD=
GITEA_ADMIN_EMAIL=admin@workspace.local

# --- the OIDC clients ----------------------------------------------------------
# Make these two applications in Gitea after Gitea starts. Refer to the runbook, step 6.
#   Name "Outline". Redirect https://<HOST_IP>:<OUTLINE_PORT>/auth/oidc.callback
#   Name "Vikunja". Redirect https://<HOST_IP>:<VIKUNJA_PORT>/auth/openid/gitea
# Set "Confidential client" to yes for both applications.
OUTLINE_OIDC_CLIENT_ID=
OUTLINE_OIDC_CLIENT_SECRET=
VIKUNJA_OIDC_CLIENT_ID=
VIKUNJA_OIDC_CLIENT_SECRET=
```

### 6.4 `init.sql`

```sql
-- init.sql makes the roles and the databases for the workspace stack.
--
-- HOW POSTGRESQL RUNS THIS FILE
--   The compose file puts this file at /docker-entrypoint-initdb.d/10-init.sql.
--   The postgres image runs the file one time only. It runs the file at the first start,
--   when the data directory is empty. After that, it does not run the file again.
--   WARNING: To run this file again, stop the stack and delete ${DATA_ROOT}/postgres.
--   This procedure deletes all of your data.
--
--   The program psql runs this file as the superuser through the local socket. At that
--   time the healthcheck holds the applications. Thus the databases are ready before an
--   application connects.
--
-- SECRET VALUES
--   This file has no passwords. The passwords come from the container environment.
--   The compose file reads them from .env. The psql backtick command puts them here.

\set ON_ERROR_STOP on

\set outline_pw `printf %s "$OUTLINE_DB_PASSWORD"`
\set gitea_pw   `printf %s "$GITEA_DB_PASSWORD"`
\set vikunja_pw `printf %s "$VIKUNJA_DB_PASSWORD"`

-- Make one role for each application. Each application has only its own data.
-- You can change one password and the other applications continue to operate.
CREATE ROLE outline LOGIN PASSWORD :'outline_pw';
CREATE ROLE gitea   LOGIN PASSWORD :'gitea_pw';
CREATE ROLE vikunja LOGIN PASSWORD :'vikunja_pw';

-- The OWNER value is important. From PostgreSQL 15, the owner of the database also owns
-- the public schema. Thus each role can make its tables. No GRANT command is necessary.
CREATE DATABASE outline OWNER outline;
CREATE DATABASE gitea   OWNER gitea;
CREATE DATABASE vikunja OWNER vikunja;

-- Only the owner can connect to its database.
REVOKE CONNECT ON DATABASE outline, gitea, vikunja FROM PUBLIC;

-- The Outline migrations need these two extensions. The superuser makes them now.
-- Thus the outline role does not need the CREATE EXTENSION permission.
\connect outline
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Gitea and Vikunja do not need an extension. They run their migrations at the first start.
```

## 7. The deployment runbook

```bash
# Step 0. The host must have docker, compose version 2, openssl and curl.
#         The command `docker info | grep -i storage` must show overlay2.

# Step 1. Make the configuration file.
cp env.example .env && chmod 600 .env
#    Set DEPLOYMENT_PROFILE, ACTIONS_URL and UPDATE_CHECKS.
#    Set HOST_IP to the address that a user types. Set DATA_ROOT and TZ.
#    Change the three port numbers if a different program uses 8081, 8082 or 8083.
#    Then make the seven secret values and the administrator password:
for k in POSTGRES_PASSWORD OUTLINE_DB_PASSWORD GITEA_DB_PASSWORD VIKUNJA_DB_PASSWORD; do sed -i "s/^$k=.*/$k=$(openssl rand -hex 24)/" .env; done
for k in OUTLINE_SECRET_KEY OUTLINE_UTILS_SECRET VIKUNJA_JWT_SECRET; do sed -i "s/^$k=.*/$k=$(openssl rand -hex 32)/" .env; done
sed -i "s/^GITEA_ADMIN_PASSWORD=.*/GITEA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20)/" .env
. ./.env

# Step 2. Make the root CA. Do this one time. The certificate has a life of 10 years.
#    Back up the certs directory with the other secret values. Refer to section 5.1.
#    The name constraint permits only the local network of HOST_IP. Thus a person with your
#    key cannot make a certificate for a different network.
#    For a larger network, change the mask. As an alternative, add a second value
#    "permitted;IP:…".
mkdir -p certs
SUBNET="${HOST_IP%.*}.0/255.255.255.0"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=Workspace Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;IP:$SUBNET" \
  -keyout certs/root.key -out certs/root.crt
chmod 600 certs/root.key; chmod 644 certs/root.crt
openssl x509 -in certs/root.crt -noout -ext nameConstraints    # Examine the constraint.

# Step 3. Make the data directories. The owner values agree with the users in the
#         containers. Caddy operates as the root user and needs no change.
mkdir -p "$DATA_ROOT"/{postgres,outline,gitea,vikunja/files,caddy}
chown 1001:1001 "$DATA_ROOT/outline"
chown -R 1000:1000 "$DATA_ROOT/gitea" "$DATA_ROOT/vikunja"

# Step 4. Start the database, the cache, Caddy and the identity provider.
docker compose up -d postgres valkey caddy gitea
docker compose ps        # Wait for the healthy condition on all four containers.

# Step 5. Make the first Gitea administrator.
#         There is no web installer, because INSTALL_LOCK is true.
docker exec -u git workspace-gitea gitea admin user create --admin \
  --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" --email "$GITEA_ADMIN_EMAIL" --must-change-password=false

# Step 6. Make the two OAuth2 clients.
#    The Gitea API has no command for an application at the level of the server. Thus these
#    commands make an application that the administrator owns. For a login, the two types
#    are the same. In the user interface, use the administrator, then Settings, then
#    Applications.
API="https://$HOST_IP:$GITEA_PORT/api/v1"; AUTH="$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD"; CA=certs/root.crt
mkapp() { curl -sf --cacert $CA -u "$AUTH" -H 'Content-Type: application/json' -X POST "$API/user/applications/oauth2" \
          -d "{\"name\":\"$1\",\"redirect_uris\":[\"$2\"],\"confidential_client\":true}"; }
mkapp Outline "https://$HOST_IP:$OUTLINE_PORT/auth/oidc.callback" | tee /dev/stderr | python3 -c \
  'import json,sys;a=json.load(sys.stdin);print(f"OUTLINE_OIDC_CLIENT_ID={a[\"client_id\"]}\nOUTLINE_OIDC_CLIENT_SECRET={a[\"client_secret\"]}")'
mkapp Vikunja "https://$HOST_IP:$VIKUNJA_PORT/auth/openid/gitea" | python3 -c \
  'import json,sys;a=json.load(sys.stdin);print(f"VIKUNJA_OIDC_CLIENT_ID={a[\"client_id\"]}\nVIKUNJA_OIDC_CLIENT_SECRET={a[\"client_secret\"]}")'
#    Copy the four lines into the .env file. WARNING: Gitea shows each client secret one
#    time only. Then start the other containers:
#
#    WARNING: If you change an application later with a PATCH command, Gitea makes a new
#    client secret. The client ID stays the same. Get the new secret from the reply, write
#    it in the .env file, then run `docker compose up -d` again. This applies when you
#    change a redirect address, for example after a change of HOST_IP or of a port.
docker compose up -d

# Step 7. Do the tests in section 8.

# Step 8. Give the root certificate to each client machine. Do this one time for each
#         machine. The file certs/root.crt is public and you can send it to a user.
#    macOS:    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.crt
#    Windows:  certutil -addstore -f ROOT root.crt              (This command needs administrator permission.)
#    Debian:   sudo cp root.crt /usr/local/share/ca-certificates/workspace-root.crt && sudo update-ca-certificates
#    Firefox has its own certificate list. Use Settings, then Certificates, then Import.
#      As an alternative, set security.enterprise_roots.enabled to true in about:config.
#    git on macOS and Windows uses the certificate list of the operating system.
#      On Windows, run: git config --global http.sslBackend schannel
#      On Linux, git uses the result of update-ca-certificates.
#      If git does not find the certificate, run:
#      git config --global http.sslCAInfo /path/root.crt
#    docker on Linux: sudo install -D -m 644 root.crt /etc/docker/certs.d/$HOST_IP:$GITEA_PORT/ca.crt
#      A restart of the daemon is not necessary.
#    docker on a desktop system: put the certificate in the list of the operating system,
#      then restart the Docker program.
#    The runner host for Gitea Actions: use the same commands. A job container that gets an
#      image from the registry also needs this certificate.

# Step 9. Get the images.
#    In the connected profile, pull the images on the target host.
#    In the isolated profile, pull the images on a build host that has external access.
#    Then move the archive to the target host.
docker compose pull
docker save $(docker compose config --images) | gzip > workspace-images.tgz
docker compose config --images | xargs -n1 docker image inspect --format '{{.RepoTags}} {{.Id}}' > workspace-images.ids
#    On the target host, run: gzip -dc workspace-images.tgz | docker load
#    Then compare the image IDs with the file workspace-images.ids.
#    Copy the full directory and include the certs directory. The CA does not change, thus a
#    client keeps its trust. Then set HOST_IP and DATA_ROOT and do steps 3 to 7.
```

### 7.1 The procedure to move PostgreSQL from version 16 to version 18

WARNING: A change of the image tag does not do this upgrade. The data format is different in
each major version. Two conditions apply to the version 18 image:

* The image puts its data in `/var/lib/postgresql/18/docker`, not in
  `/var/lib/postgresql/data`.
* The image does not start if the compose file mounts a directory at
  `/var/lib/postgresql/data`. An empty directory also stops the start. You must remove that
  mount line and put a mount at `/var/lib/postgresql`.

Do these steps in this sequence:

1. Get the version 18 image on a host that has external access. Then move it to the target
   host.
2. Stop the applications. Keep PostgreSQL in operation:
   `docker compose stop caddy gitea outline vikunja`
3. Make the dump with the **version 18** program, not the version 16 program. The version 16
   image has only version 16 programs. Use a temporary container on the compose network.
   The new `psql` is also necessary for the restore, because a dump from 2026 or later
   contains the commands `\restrict` and `\unrestrict`.
   WARNING: Do not use the options `--clean` and `--if-exists`. The new cluster is empty and
   needs no DROP command. With those options the dump contains `DROP ROLE postgres`,
   `DROP DATABASE postgres` and `DROP DATABASE template1`. Each of those commands fails, and
   `ON_ERROR_STOP` then stops the restore. The correct command is:
   `pg_dumpall -h <source> -U postgres > dump.sql`
4. Stop PostgreSQL with a long time limit: `docker compose stop -t 120 postgres`
5. WARNING: Do not delete the old data directory. Change its name:
   `mv "$DATA_ROOT/postgres" "$DATA_ROOT/postgres-16.bak"`
6. In the compose file, change the image tag to `18.6-alpine` and change the mount to
   `${DATA_ROOT}/postgres:/var/lib/postgresql`.
7. Remove the `init.sql` mount for this start. WARNING: Do not omit this step. The file makes
   the roles in the new empty database, and the restore then fails with the message
   `role "outline" already exists`. The dump contains the roles, the databases, the
   permissions and the extensions.
8. Start PostgreSQL: `docker compose up -d postgres`
9. Remove one line from the dump. WARNING: Do not omit this step. Each new cluster already
   has the role `postgres`, and the dump contains the command `CREATE ROLE postgres`. That
   command fails and stops the restore.
   `sed '/^CREATE ROLE postgres;$/d' dump.sql > dump-filtered.sql`
10. Restore the filtered dump with the version 18 `psql` and the options
    `-X -v ON_ERROR_STOP=1`. The result must be exit code 0 and no error line.
11. Make the statistics again: `vacuumdb --all --analyze-in-stages`. A restore has no
    statistics for the query planner.
12. Put the `init.sql` mount back. Then start the applications. The file does not operate
    again, because the data directory is not empty.

To go back to version 16, change the tag and the mount to their old values and change the
name of the old directory back. The old directory is the fastest method to go back.

NOTE: Version 18 makes data checksums at the initialization. Your version 16 cluster has no
checksums. This procedure gives the checksums to the new cluster.

NOTE: Version 18 starts three more background processes for its input and output. Examine
the memory of the container after the upgrade.

## 8. The test list

```bash
. ./.env; CA=certs/root.crt
docker compose ps
docker compose config --images
docker info | grep -i 'storage driver'
docker stats --no-stream $(docker compose ps -q)

# The TLS chain must be correct against your root certificate.
# WARNING: Do not use the curl option -k in these commands. That option stops the test.
echo | openssl s_client -connect $HOST_IP:$GITEA_PORT -CAfile $CA 2>/dev/null | grep 'Verify return code'
curl -s --cacert $CA -o /dev/null -w 'gitea   %{http_code}\n' https://$HOST_IP:$GITEA_PORT/api/healthz
curl -s --cacert $CA -o /dev/null -w 'outline %{http_code}\n' https://$HOST_IP:$OUTLINE_PORT/_health
curl -s --cacert $CA -o /dev/null -w 'oidc    %{http_code} -> %{redirect_url}\n' https://$HOST_IP:$OUTLINE_PORT/auth/oidc   # The correct code is 302 to Gitea.
curl -s --cacert $CA https://$HOST_IP:$VIKUNJA_PORT/api/v1/info | python3 -m json.tool | grep -A14 '"auth"'                 # The list providers[] must have one item.
curl -s --cacert $CA https://$HOST_IP:$GITEA_PORT/.well-known/openid-configuration | python3 -m json.tool | grep -E 'issuer|_endpoint'
curl -s --cacert $CA -o /dev/null -D - https://$HOST_IP:$GITEA_PORT/v2/ | grep -iE '^HTTP|www-authenticate'   # The correct code is 401 with a Bearer realm.

# Examine the PostgreSQL roles, databases and extensions.
docker exec workspace-postgres psql -U postgres -c '\du' -c '\l'
docker exec workspace-postgres psql -U postgres -d outline -c '\dx'

# Examine the trust of the root certificate in the two containers.
docker exec workspace-outline node -e "fetch('https://$HOST_IP:$GITEA_PORT/api/healthz').then(r=>console.log(r.status)).catch(e=>console.log('FAIL',e.cause?.code))"
docker compose logs vikunja | grep -iE 'x509|openid'     # This command must show no line.

docker compose logs --tail=60 gitea outline vikunja caddy
```

Do these checks manually and record the result:

1. In Outline, select "Continue with Gitea". Does the first login make the workspace? Does
   an installation page come first? If you see an authentication error, examine the Outline
   log for the message "invalid client secret". Refer to section 9.2.
2. In Vikunja, select "Log in with Gitea". Does Vikunja make the user account with the
   correct name and the correct email address?
3. Upload an attachment in Outline. Upload an attachment in Vikunja.
4. Do a `git push` to `ssh://git@$HOST_IP:2222`. Then do a `git push` with HTTPS.
5. Run `docker login $HOST_IP:$GITEA_PORT`, then push an image. The root certificate must be
   in the `certs.d` directory.
6. Edit one page in Outline from two browsers at the same time. This test uses a websocket
   through Caddy.

## 9. The verification log

A test host ran the full stack on 2026-09-06. This section records the result of each test.

The test host had Docker 29.6.1, Compose 5.3.0, 8 GB of memory and an overlay storage
driver. It used the `connected` profile. This host has a desktop Docker runtime and not a
native Linux daemon. This condition changed three items. `DATA_ROOT` was in the project
directory. The bind mounts ignored the owner values on the host, thus the `chown` commands
were not necessary. Vikunja moved to port 8084, because a different program used port 8083.
All other values are the same as the file in section 6.1. Section 10 lists each item that
needs a native Linux daemon.

### 9.1 Outline 1.8.0

* Outline operates as `uid=1001(nodejs)`. The image has its own HEALTHCHECK, and it uses
  `wget /_health`. The address `/_health` gives the code 200.
* Outline accepted `FILE_STORAGE=local`, `FILE_STORAGE_LOCAL_ROOT_DIR` and
  `FILE_STORAGE_UPLOAD_MAX_SIZE`. The start was correct. A file upload is not verified.
* Outline accepted `OIDC_AUTH_URI`, `OIDC_TOKEN_URI` and `OIDC_USERINFO_URI`. The address
  `/auth/oidc` makes the correct authorize address. It has `response_type=code`, the correct
  `redirect_uri`, the scope `openid profile email` and the correct `client_id`. The reply
  from `auth.config` has one provider with the name "Gitea".
* With one provider, the address `/` gives the code 200. The user interface then starts the
  OIDC procedure. No installation page came before the login. The condition after a login is
  not verified.
* **Outline needs HTTPS.** Refer to decision D5. A test on an HTTP connection gave the error
  500. The source code at tag v1.8.0 has the value `secure: env.isProduction`. Outline
  operates correctly behind Caddy with `app.proxy = true` and the header
  `X-Forwarded-Proto`. With `NODE_EXTRA_CA_CERTS`, the request from Outline to Gitea is
  correct. It gave the code 401, because the test had no token. Thus the TLS connection is
  correct.
* Outline accepted `PGSSLMODE=disable` and `FORCE_HTTPS=false`. The second value causes one
  warning line in the log.

### 9.2 Gitea 1.26

* The tag is available. The image has the command `curl`, thus the healthcheck operates. The
  address `/api/healthz` gives the code 200.
* The variable `GITEA__cron_0X2E_update_checker__ENABLED` goes to the section
  `[cron.update_checker]`. The variables `ROOT_URL`, `DOMAIN`, `SSH_DOMAIN`, `SSH_PORT`,
  `LFS_START_SERVER` and `REVERSE_PROXY_TRUSTED_PROXIES` go to the file `app.ini` with the
  correct values.
* The command `gitea admin user create --admin … --must-change-password=false` operates.
* In the discovery file, the **issuer is `ROOT_URL` without the last slash**. The value
  `scopes_supported` includes `openid`, `profile`, `email` and `groups`. The value
  `claims_supported` includes `email`, `email_verified`, `preferred_username` and `groups`.
  The token address is `/login/oauth/access_token`.
* You can make an OAuth2 application with `POST /api/v1/user/applications/oauth2`. Use
  `redirect_uris[]` and `confidential_client:true`. You can change it with `PATCH …/{id}`.
  Both commands operate with basic authentication. The API has no command for an application
  at the level of the server.
* **WARNING: A `PATCH` command makes a new client secret.** The client ID does not change,
  but the old secret stops. The reply to the `PATCH` command contains the new secret. Write
  that new secret in the .env file. Then run `docker compose up -d` to make the containers
  again. If you do not do this, the login gives the message "invalid client secret" in the
  Outline log. The user sees an authentication error. The Vikunja provider list stays
  correct in this condition, because that list comes from the discovery file and not from
  the secret.
* The container registry gives the code 401 for `GET /v2/` through Caddy. The reply has the
  header `Www-Authenticate: Bearer realm="https://HOST_IP:8082/v2/token"`.

### 9.3 Vikunja 2.3.0

* The provider configuration with environment variables operates. The address `/api/v1/info`
  shows `auth.openid_connect.providers[]`. The value `auth_url` comes from the discovery
  file. The value `auth.local.enabled` is false.
* The variable `VIKUNJA_SERVICE_JWTSECRET` causes a warning: "deprecated, using
  service.secret". The name `VIKUNJA_SERVICE_SECRET` removes the warning.
* Vikunja obeys `PUID` and `PGID`. The process operates as user 1000.
* The image is a distroless image. It has no `sh`, no `ls` and no `wget`. It also has no
  HEALTHCHECK. Use the log and the command `docker top` to examine this container.
* Vikunja accepted `VIKUNJA_DATABASE_HOST=postgres:5432` and ran the migrations. Vikunja
  obeys `SSL_CERT_FILE`.
* **Vikunja tries the discovery request three times at the start.** Then it continues with an
  empty provider list and does not try again. Thus `depends_on` includes `gitea` and `caddy`
  with the condition `service_healthy`. If Gitea was not available at the start, run
  `docker compose restart vikunja`.

### 9.4 PostgreSQL 16 and Valkey 8.1

* The file `init.sql` ran on the empty data directory. It made the roles `outline`, `gitea`
  and `vikunja`. Each role owns its database. The database `outline` has `uuid-ossp` 1.1 and
  `pg_trgm` 1.6.
* The psql backtick command in `\set` operates under the entrypoint.
* PostgreSQL accepted `REVOKE CONNECT ON DATABASE a, b, c FROM PUBLIC`. The command is
  effective: the role `gitea` cannot connect to the database `outline`.
* The healthcheck `pg_isready -h 127.0.0.1` gives the healthy condition approximately 10
  seconds after the start. The applications waited correctly.
* The image `valkey/valkey:8.1-alpine` is available. The command `valkey-cli ping` operates
  without a password.

### 9.5 Compose

* Compose 5 obeys `deploy.resources.limits.memory` without swarm mode. The command
  `docker stats` shows the limits.
* The forms `${VAR:?msg}` and `${VAR:-default}` operate. The condition
  `depends_on.condition: service_healthy` operates.
* The YAML values `!override` and `!reset` operated in the revision 2 override file. That
  file is no longer necessary.

### 9.8 The PostgreSQL migration of 2026-09-08

A test host moved the cluster from version 16.15 to version 18.6 with the procedure in
section 7.1. The result:

* The version 18 image put its data in `/var/lib/postgresql/18/docker`. The mount is at
  `/var/lib/postgresql`.
* Data checksums are on in the new cluster. The version 16 cluster had no checksums.
* The dump kept each role, each database with its owner, the five extensions in the
  `outline` database, the Gitea administrator and the two OAuth2 applications. The two
  client secrets stayed correct, thus no application needed a new secret.
* The command `REVOKE CONNECT` stays effective. The role `gitea` cannot connect to the
  database `outline`.
* Two commands in the first dump stopped the restore. The corrections are in section 7.1,
  steps 3 and 9. The correct restore gives exit code 0 and no error line.
* The old data directory stays on the disk with the name `postgres-16.bak`.

### 9.7 The upgrade of 2026-09-08

The stack moved from its first versions to the versions in section 3. A test host did each
step and examined the result. The sequence was Gitea, then Valkey and Caddy, then Vikunja,
then Outline.

* **Gitea 1.26.4 to 1.27.3.** Migrations 331 to 342 operated correctly. The OIDC discovery
  file did not change, and the issuer has no slash at the end. The two OAuth2 applications
  and their client secrets stayed correct. No secret was necessary again.
* **Valkey 8.1.10 to 9.1.2.** The reported Redis version stays 7.2.4, thus a Redis client
  operates without a change. Persistence stays off. The command `valkey-cli ping` gives PONG.
* **Caddy 2.10.2 to 2.11.4.** The TLS chain gives the result `0 (ok)` against the root
  certificate. NOTE: During the first minute, three requests gave no reply. The log shows
  that Caddy made a new server certificate at that time. The requests were correct after
  that minute.
* **Vikunja 2.3.0 to 2.6.0.** Migrations operated correctly. The provider list has Gitea and
  local login stays off. Vikunja writes one warning about a license key. That function makes
  no external request when the key is empty.
* **Outline 1.8.0 to 1.10.0.** Twelve migrations operated correctly. No environment variable
  needed a change. The extension `btree_gin` was made by the superuser before the upgrade,
  because the `outline` role cannot make an extension.
* After all five upgrades: each container is healthy, the three health addresses give 200,
  the Outline login start gives 302, both client secrets are correct, and the request from
  the Outline container to Gitea gives 200. There is no x509 error and no error in the log.
* The memory of the stack went from approximately 540 MB to approximately 690 MB.

### 9.6 Caddy

* **The listener wrapper `http_redirect` operates in the standard image.** The command
  `caddy list-modules` shows `caddy.listeners.http_redirect` in `caddy:2.11.4-alpine`. An
  HTTP request to each of the three TLS ports gives the code 308 with the same address and
  the scheme `https`. The path and the query stay the same. A request that follows the
  answer gives the code 200.
* **WARNING: A global `servers` block gives the wrapper to each listener.** If you add a
  plain-HTTP page on port 80, write one block for each port, for example
  `servers :8081 { }` and `servers :80 { protocols h1 h2c }`. Without that separation, the
  page on port 80 answers with a redirect to `https://<address>:80`, and no service listens
  there.
* **The wrapper examines only five request methods**: GET, HEAD, POST, PUT and OPTIONS. A
  plain-HTTP request with a different method gets no answer. A browser is not affected.
* **The command `caddy validate` stops with a Go panic if the PKI files are absent.** Mount
  the `certs` directory into the container for that test. The panic is not a fault in the
  configuration.
* **No browser corrects this condition.** Chrome does not change HTTP to HTTPS for an IP
  address or for an address with a port. Firefox has the two options
  `https_first_for_custom_ports` and `https_first_for_local_addresses`, and both are off.
  RFC 6797 does not permit HSTS for an IP address. Thus the correction must be on the
  server.
* **A name gives a better result than an IP address, but each client needs a step.** RFC 6797
  keeps a port that is not 80 and changes only the scheme. Thus HSTS operates for a name.
  A name also removes the necessity for the option `default_sni`.
  WARNING: Do not use mDNS and a `.local` name to avoid that step. Windows added mDNS to its
  new interfaces, and reports show that a `.local` name does not operate in an older Win32
  program or in the command `ping`. A browser on Windows uses the Win32 interface. Examine
  this behaviour on your own Windows version before you make a decision.
  A line in the hosts file of each client is reliable on Linux, macOS and Windows. Add that
  line at the same time as the root certificate. Refer to section 7, step 8.
  A name that ends with `.internal` is a good selection. ICANN keeps that name for private
  use, thus it cannot conflict with a public name.

### 9.6.1 Caddy 2.10.2 (earlier observations)

* The configuration `pki { ca local { root { cert key } } }` operates with an EC root
  certificate from openssl. Caddy made the intermediate certificate "Workspace Root CA - ECC
  Intermediate". The server certificate has `SAN IP:HOST_IP`. The command `openssl verify`
  gives the result `0 (ok)` against `certs/root.crt`.
* The line `default_sni` is necessary for an IP address. Refer to correction 5 in section
  2.1.
* The admin API listens on `127.0.0.1:2019`. Thus the healthcheck must use the IP address.
  Refer to correction 4 in section 2.1.
* The line `servers { protocols h1 h2 }` removes the UDP buffer warning for HTTP/3.
* **WARNING: Caddy keeps an old intermediate certificate.** If `${DATA_ROOT}/caddy` has an
  intermediate certificate from a different root, Caddy continues to use it. The TLS chain is
  then not correct. Delete the contents of that directory when you change the root.
* Caddy sends the Gitea registry reply 401 and the header `Www-Authenticate` without a
  change. An HTTP request to a TLS port gives the code 400.
* **The name constraint operates.** The root certificate has
  `nameConstraints=critical,permitted;IP:192.168.1.0/255.255.255.0`. The command `openssl
  verify` accepts the chain from the server. A test certificate for `IP:10.0.0.5` from the
  same key gives the result "verification failed". A test certificate for `IP:192.168.1.50`
  gives the result OK.
* **A new root certificate does not go to a container that operates.** The file bind mount
  keeps the old file. Outline gave the message "Ignoring extra certs … bad end line" until a
  restart.

## 10. The items that are not verified

* A login from a browser, and the condition after a login. These three items are not
  verified:
  1. The Outline workspace.
  2. The Vikunja user account, with `ENABLEREGISTRATION=false`.
  3. The behaviour of Outline for a user that has the same email address.
* A file upload in Outline and in Vikunja.
* A `git push` with SSH and a `git push` with HTTPS.
* A `docker login` and a `docker push` with the root certificate in the `certs.d` directory.
  Only the registry address was examined.
* The websocket for the collaboration function in Outline. Caddy sends an upgrade request
  without a change. A test with curl was not conclusive. It gave the code 400, because the
  test had no socket.io data. Do this test from a browser.
* The behaviour on a **native Linux daemon**. Two items are different. The owner of a bind
  mount is important, thus the `chown` commands in step 3 are necessary. The connection from
  a container to `HOST_IP:port` goes through the host bridge. Both items are usual Docker
  behaviour, but they are not verified here. WARNING: If a host does not permit that
  connection, use `extra_hosts` or an internal name for Caddy. Do not change `AUTHURL` to
  `http://gitea:3000`. That address does not agree with the issuer. Refer to decision D7.
* The behaviour with a **vendor interface for Compose**. Some hosts do not use the command
  line. Examine these items on such a host:
  1. The values in `deploy.resources.limits`.
  2. The conditions in `depends_on`.
  3. The bind mounts `./init.sql`, `./Caddyfile` and `./certs`. A relative path is correct
     if the project operates from its own directory.
  4. The owner values on the vendor storage path.
  5. cgroup version 1 on an old kernel.
* **Gitea Actions.** This includes `ACTIONS_URL=self`, the copy of `actions/*` into a local
  organization, and the runner images. You must load the runner image and the job images
  before you start. The runner host must also trust `root.crt`. Actions are not verified in
  the two profiles.
* The memory of Outline. It uses 340 to 520 MB, and the first estimate was 300 to 500 MB. The
  limit of 1 GB is sufficient. Examine this value on a host with 8 GB and with usual work.
* The value `REVERSE_PROXY_TRUSTED_PROXIES="*"` in Gitea. This value is satisfactory, because
  port 3000 is not open on the host. If you open that port, change the value to the compose
  network address.

## 11. Reviewer mission

Examine revision 3 of this stack. Obey these rules:

* Do not examine the decisions D1 to D6 again. Examine them only if you find a specified
  error.
* Keep two limits: all of the software must be free and open source, and the `isolated`
  profile must make no external connection.
* Use the current documentation of each program. Do not use your memory of it. If you cannot
  find the necessary documentation, write that condition in your report.
* Section 9 has the verified items. Section 10 has the items that are not verified.

Do these five tasks:

1. **Examine each variable, each path and each command option in section 6.** Use the
   documentation for these versions: Outline 1.8, Gitea 1.26, Vikunja 2.3, PostgreSQL 16,
   Valkey 8.1 and Caddy 2.10. Report each item that has a new name, each item that is
   obsolete and each item that has a different default value.
2. **Examine the output of section 8.** Look for each of these conditions:
   * A container that is not healthy.
   * A TLS chain that is not correct.
   * A role, a database or an extension that is not there.
   * An address that gives an incorrect code.
   * An incorrect issuer.
   * An empty provider list in Vikunja.
   * An x509 error.
   * A permission error on a bind mount.
3. **Examine the OIDC procedure and the trust model in section 4.** Look at the redirect
   addresses. Look at the issuer comparison. Look at the email claim for Outline. Look at
   the first login. Then examine the connection from a container to the host port on a
   native Linux daemon. Report each condition that can cause a browser or a command to
   refuse the private CA.
4. **Examine the isolation.** Refer to section 10. Look at these four items:
   * The Actions runner images.
   * The value `ACTIONS_URL=self`.
   * Each external connection that a container can make in the `isolated` profile.
   * The image transport and the comparison of the image IDs.
5. **Examine the platform and the memory.** Refer to section 10. Report each item that
   operates differently with a vendor interface for Compose or with an old kernel. Use the
   values from `docker stats` and compare the total with the budget of 6.5 GB.

Write your report in this format: put the most severe item first. For each item, give the
exact line in section 6 that needs a change.
