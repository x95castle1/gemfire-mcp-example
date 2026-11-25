# 10: Security (cluster auth → OAuth + RBAC → TLS)

```bash
# On: one line in .env, then restart everything at once
echo 'COMPOSE_FILE=compose.yaml:compose.security.yaml' >> .env
make stop && make start        # never `make start` alone when switching (see "Switching" below)
make sre                       # log in at http://localhost:18080 as jeremy / VMware1! (or andrew, robert, admin, viewer)
make call T=search_logs C=viewer          # RBAC: the read-only client is refused this tool
scripts/mcp-token.sh --claims             # what's inside a token
# Off: delete the COMPOSE_FILE line from .env, then make stop && make start
```

Until this chunk the lab had no real security:
- the MCP server took admin/admin
- GemFire let anyone read and change anything on :17070
- everything was plain http

This chunk adds three layers, all in **one overlay file**, `compose.security.yaml`. Off (the default), the lab is exactly as before.

```
                 ┌──────────── 10b: OAuth 2.1 (Keycloak) ────────────┐      ┌─ 10a: GemFire SecurityManager ─┐
 you (Chrome) ─login─▶ SRE app ──token exchange──▶ Keycloak            │      │                                │
                         │  MCP token in YOUR name (aud=gemfire-mcp-server, scope=gemfire:read [gemfire:logs])     │
                         ▼                                                    │                                │
 Claude Code / make call / Inspector ──Bearer──▶ MCP server ──Basic "mcp" (CLUSTER:READ)──▶ locator REST :7070  │
                                                  │ checks: signature, iss, aud, per-tool scope            ▲   │
                                                  └ audit: principal, outcome                 workload ─"workload"─┘
 10c: every arrow above that's HTTP is https, with certificates from a lab CA (./data/certs)
```

## How the switch works

**`compose.security.yaml`** is merged on top of `compose.yaml` when `COMPOSE_FILE` lists both. Docker Compose reads that variable from `.env`, and so do the Makefile and every script (`scripts/security.sh` → `sec_on`). Compose merges per key:
- environment variables are added or replaced
- `depends_on` entries are added
- a volume with the **same target path** replaces the one in `compose.yaml`

That last rule is the trick for GemFire. Every member always starts with:

```
--security-properties-file=/security/gfsecurity.properties --classpath=/security
```

and what's mounted at `/security` decides everything:

| Mode | Mounted at `/security` | Contents |
|---|---|---|
| off | `security/gemfire-off/` | an empty properties file |
| on | `security/gemfire-on/` | SecurityManager, the members' own login, `security.json` (users and roles), TLS settings |

The member commands never change. Prometheus's gemfire job works the same way: `scrape.d/` is swapped for an https version.

**Things that are always sent, harmless when security is off:**
- the healthchecks' `Authorization` header
- `chaos.sh`'s locator calls
- the Prometheus scrape's `basic_auth`
- gfsh's `connect --user=cluster`

GemFire without a SecurityManager ignores credentials, which we checked in both modes.

**Switching** is `make stop && make start`. All members must change together: a secured member and an unsecured one can't form a cluster. `make start` on its own would recreate all three servers at once and hit chunk 6's quorum deadlock.

**GemFire remembers that security was on.** While the locator runs secured, the **cluster configuration** records the `security-manager`. That's the configuration the locator keeps in `data/gemfire/locator/ConfigDiskDir_locator` and hands to every server that joins. Switch security off and the setting stays there. The servers then inherit it, look for a `security.json` that's no longer mounted, and exit:

```
[info  ...] The security-manager configuration attribute can not be modified.
[error ...] AuthenticationFailedException: ExampleSecurityManager: unable to find json resource "security.json" as specified by [security-json].
[fatal ...] Server is shutting down due to an exception during startup
```

So `make start` first runs `scripts/security.sh guard`:
1. It compares the mode with the one it last started in (`data/.security-mode`).
2. When the mode changed, it resets the cluster configuration and says so:

   ```
   Security switched on -> off: resetting GemFire's cluster configuration (it remembers the security-manager).
   ```

   gemfire-init then recreates the regions. The persistent `Orders` region's data lives in the servers' own disk stores: still 10,000 entries after a switch.
3. If the cluster is still running, it refuses and asks for `make stop && make start`. (Broadcom file, #13.)

## Accounts

| Who | Password | Where | May |
|---|---|---|---|
| `admin` | admin | GemFire, Keycloak (realm `gfmcp`, group `sre`; also the admin console in realm `master`) | everything / read + logs |
| `jeremy`, `andrew` | VMware1! | Keycloak, group `sre` | MCP: read + logs |
| `robert`, `viewer` | VMware1! / viewer | Keycloak, group `viewers` | MCP: read only (no `search_logs`) |
| `cluster` | cluster | GemFire | members joining each other, gfsh init (`CLUSTER:*`, `DATA:MANAGE`) |
| `mcp` | mcp | GemFire | the MCP server: `CLUSTER:READ` only |
| `monitor` | monitor | GemFire | healthchecks, Prometheus, chaos.sh: `CLUSTER:READ` |
| `workload` | workload | GemFire | the workload: `DATA:READ`/`WRITE` on its 4 regions |
| clients `lab-cli` / `lab-viewer` | `<name>-secret` | Keycloak, client credentials | scripts, Claude Code, Inspector / the RBAC demo |
| client `sre-assistant` | sre-assistant-secret | Keycloak | the SRE app's login, token exchange, and its own read-only service account |
| keystores | changeit | `./data/certs` | |

All plain text in files, on purpose: it's a lab. Real systems use a SecurityManager backed by LDAP/an IdP, a vault for secrets, and an IdP that isn't running in `start-dev` mode.

## 10a: GemFire's own security

GemFire ships `org.apache.geode.examples.security.ExampleSecurityManager` in `gemfire-core`. It reads users, passwords and roles from `security.json` on the classpath (hence `--classpath=/security`). A permission is `RESOURCE:OPERATION[:REGION]`:
- resource: `CLUSTER` or `DATA`
- operation: `READ`, `WRITE` or `MANAGE`
- a role's `regions` narrows its `DATA` permissions

`MANAGE` doesn't include `READ`.

**What changes:**

| Check | Result |
|---|---|
| `curl localhost:17070/management/v1/members` (no credentials) | **401**, even `/ping` |
| … `-u mcp:mcp` | 200 |
| `POST /management/v1/regions` as `mcp` | `"Mcp not authorized for DATA:MANAGE."` |
| developer REST `/gemfire-api/v1/Customers` | none: 401 · `workload`: 200 · `monitor`: **403** (no `DATA:READ`) |
| `/metrics/` | 401 without credentials, so Prometheus logs in as `monitor` |
| workload with a wrong password | servers log `Security exception: org.apache.geode.security.AuthenticationFailedException`, which `search_logs` can find |

**The MCP server needs only `CLUSTER:READ`.** Every live-state tool (`list_members`, `list_regions`, `assess_cluster_health`, `get_partition_region_health`) worked as `mcp`. It logs in with `GF_MCP_GEMFIRE_AUTH=username-password`, as HTTP Basic, which is what `/management/v1` accepts. The JAR's comments explain why `token-delegation` is refused in 1.0: forwarding the caller's own token to GemFire is "token passthrough", which the MCP spec forbids.

**The forwarder is unaffected.** It reads files and writes to S3; it never talks to the cluster. The logs and stats in the telemetry store are protected by the store's credentials (SeaweedFS admin/admin), not by GemFire's.

**gfsh prints the password.** `gfsh run --file` masks it in the `Executing` line but repeats it in clear in its summary (`Command-1 : connect --locator=locator[10334] --user=cluster --password=cluster`), so it appears in `make start`'s output. In the Broadcom file as #12.

Until 10c the MCP server needs `GF_MCP_GEMFIRE_ALLOW_INSECURE_URL=true`, because `username-password` over plain http to another host is refused at startup. It logs: *"gf-mcp.gemfire.url 'http://locator:7070' is plaintext and not loopback, allowed only because …allow-insecure-url=true. The username and password sent on every cluster call…"*.

## 10b: OAuth at the MCP front door, per-tool RBAC, people logging in

### Keycloak, and one name that works everywhere

A token carries its issuer (`iss`). The MCP server only accepts tokens whose `iss` equals its configured issuer, and it downloads the signing keys from that same address. So the browser on your Mac, the SRE app and the MCP server must all reach Keycloak **by the same URL**. `localhost:18180` would be the MCP server itself, inside its container, and `keycloak:18180` doesn't resolve on your Mac without an `/etc/hosts` line.

The answer is **`keycloak.localhost:18180`**:
- Inside Docker it's a network alias of the Keycloak container.
- On the Mac, Chrome and curl send every `*.localhost` name to 127.0.0.1 by themselves (RFC 6761).
- Keycloak listens on 18180 inside and out, and `KC_HOSTNAME` pins the issuer.

Three things don't follow the RFC 6761 rule, and each one cost us time:
1. **macOS's own resolver** doesn't map `*.localhost`. Python and Node on the Mac can't resolve it (curl and Chrome can). The test script maps it itself.
2. **Netty's DNS resolver** (inside the SRE app, brought in by Spring AI) *does* map `*.localhost` to 127.0.0.1, even inside a container, without asking Docker's DNS. `RestClient.create()` and Spring Security's token client both pick Reactor Netty when it's on the classpath. The login silently ended at `/login?error`, and our own token calls got "Connection refused: localhost/127.0.0.1:18180". Both now use the JDK HTTP client (`McpTokens`, `SecurityConfig.tokenClient()`).
3. **Secure cookies over http.** Keycloak marks its login cookies `Secure`. Chrome sends them to `http://*.localhost` (a "potentially trustworthy" origin); curl does so only for the literal `localhost`, so a scripted curl login fails with a 400.

### Scopes, roles, audience (`security/keycloak/gfmcp-realm.json`)

- **Client scopes** `gemfire:read` (it also adds the audience `gemfire-mcp-server`) and `gemfire:logs`.
- **Role-gated:** a client scope with a role scope mapping is granted only to users holding that role.
  - group `sre` → roles `gemfire-reader` + `gemfire-log-reader`
  - group `viewers` → only `gemfire-reader`

  Nobody "asks" for less: a viewer's token simply never contains `gemfire:logs`.
- **The SRE app's login token** has only `openid profile`, with `aud=sre-assistant`. It isn't valid at the MCP server; only the exchanged token is.

### The MCP server in OAuth mode

| Setting | Value |
|---|---|
| `GF_MCP_AUTH_MODE` | `oauth` |
| `GF_MCP_AUTH_OAUTH_ISSUER_URI` | `https://keycloak.localhost:18180/realms/gfmcp` (http plus `ALLOW_INSECURE_ISSUER` before 10c) |
| `GF_MCP_AUTH_OAUTH_AUDIENCE` | `gemfire-mcp-server`: a token Keycloak minted for another app is refused |
| `GF_MCP_AUTH_OAUTH_PRINCIPAL_CLAIM` | `preferred_username`, so the audit names `jeremy`, not a UUID |
| `GF_MCP_AUTH_OAUTH_RBAC_ENABLED` | `true`: every tool needs `gemfire:read` (fixed) |
| `tool-scopes` | `search_logs: gemfire:logs`, in a **file** (`security/mcp/application-security.yml` via `SPRING_CONFIG_ADDITIONAL_LOCATION`), because a map key with an underscore can't be an environment variable (relaxed binding turns `_` into `.`) |
| `GF_MCP_AUTH_FAILURE_LIMIT_ENABLED` | `true` again, so failed logins are audited (issue #9.3) |

What the server shows the world:
- **`GET /.well-known/oauth-protected-resource`** (no login needed) → `{"resource":"https://localhost:8085","authorization_servers":["https://keycloak.localhost:18180/realms/gfmcp"],"scopes_supported":["gemfire:read"],...}`
- A 401 says the same thing: `WWW-Authenticate: Bearer realm="gf-mcp-server", resource_metadata=".../.well-known/oauth-protected-resource/mcp", scope="gemfire:read"`.

That's how an MCP client discovers where to log in (RFC 9728).

**RBAC denial** is a *tool* error (HTTP 200, `isError: true`), not a 403, so the model sees it and can react:

```
make call T=search_logs C=viewer
→ isError: true   Access denied: tool 'search_logs' requires scope 'gemfire:logs'.
```

The audit line for it is the only one that names a tool:

```json
{"principal":"service-account-lab-viewer","event":"http_request","status":200,"outcome":"denied","tool":"search_logs","requiredScope":"gemfire:logs","reason":"missing_scope"}
```

Grafana's MCP row now shows **Requests / min by principal and outcome** (success / denied / auth_failure).

**A healthcheck gotcha.** The MCP server's healthcheck used to `GET /mcp` without credentials. With the failure limit back on, every probe was an audited `auth_failure` (from 127.0.0.1, every 3 s), counted toward the 50-per-5-minutes throttle. It now probes `/.well-known/oauth-protected-resource`, which needs no login and isn't audited.

### People log in to the SRE app, and MCP sees *them*

`make sre` → http://localhost:18080 → Keycloak's login page → back to the chat, *"signed in as jeremy · sign out"*.

1. **Login:** Spring Security `oauth2Login`, authorization code **with PKCE** (`SecurityConfig`). Active only with the `security` profile, which `compose.security.yaml` sets; otherwise the app is open as before. The page sends Spring's CSRF token (`XSRF-TOKEN` cookie → `X-XSRF-TOKEN` header).
2. **Token exchange (RFC 8693)** at the start of every question (`McpTokens.exchange`): the app swaps your login token for a token **for the MCP server, in your name**:

   ```
   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
   subject_token=<your login token>   audience=gemfire-mcp-server   scope=gemfire:read gemfire:logs
   ```

   Keycloak grants only the scopes your roles allow. The trace shows it first: `token exchange: MCP token for robert · scope gemfire:read profile`.
3. **Every MCP call of that question carries that token** (`McpClientConfig` reads it from the active investigation).
4. **Outside a question** (the MCP handshake at startup, `tools/list`), the app uses **its own** service account (client credentials, read only). The audit shows `service-account-sre-assistant` for those.

Same question, *"Were there any warnings or errors in the GemFire logs in the last 15 minutes? Check the logs."*, with Qwen:

| Who | MCP token scope | What happened |
|---|---|---|
| **robert** (viewers) | `gemfire:read profile` | `search_logs` → *Access denied*. Qwen fell back to `assess_cluster_health` and answered *"even though direct log access was denied…"*, listing the forced disconnects and the quorum loss from the health check. |
| **jeremy** (sre) | `gemfire:logs gemfire:read profile` | `search_logs` → 15,704 chars of WARN+ lines, answered from them |

MCP audit for those runs: `jeremy success`, `robert denied search_logs`, `robert success ×2`, `service-account-sre-assistant success ×4` (startup).

(Claude wasn't run in this round: the lab was restarted from a shell without `ANTHROPIC_API_KEY`. `make sre` from your shell passes it.)

**Two findings** (#10 and #11 in the Broadcom file):
- **Per-tool scopes don't hide log *content*.** robert couldn't call `search_logs`, but `assess_cluster_health` (allowed) told him *"3 partition lines were logged"* and when members were forced out. Its `membership_events` check reads the logs. To really keep a group away from logs you'd also have to gate `assess_cluster_health`, `get_membership_timeline` and `collect_member_departure_evidence`, which leaves viewers with little.
- **An MCP session isn't bound to who opened it.** A session opened with `lab-cli`'s token accepted `tools/list` with `lab-viewer`'s token. Every request is still authenticated and scope-checked on its own, so nothing leaks, and it's exactly why the SRE app can open one session as itself and then call tools as you. But the MCP security best practices say servers should bind session IDs to the user.

### Other clients

| Client | How it authenticates (security on) |
|---|---|
| `make call` / `scripts/mcp-curl.sh` | a fresh `lab-cli` token (`C=viewer` → `lab-viewer`) |
| `scripts/mcp-token.sh` | prints the header value; `--claims` decodes a token; `--headers` prints JSON |
| **Claude Code** | `.mcp.json` now has `"headersHelper": "scripts/mcp-token.sh --headers"`: a fresh header on every connect, Basic or Bearer depending on the mode. Claude Code asks you to **approve** the changed project server once (`claude`, then `/mcp`). |
| **MCP Inspector** | `make inspector` recreates it with a fresh 1-hour token |

## 10c: TLS

The one-shot **`certs`** service runs `security/certs/make-certs.sh`, using the GemFire image's `keytool` and `javac`, into `./data/certs` (once; `rm -rf data/certs` to redo):

| File | What it is |
|---|---|
| `ca.p12`, `ca.pem` | the lab CA. Clients trust `ca.pem`. It needs `keyUsage=keyCertSign`: strict clients refuse a CA without it (Python 3.13: *"CA cert does not include key usage extension"*) |
| `lab.p12` | one key pair for every endpoint. SAN: `localhost, 127.0.0.1, locator, server-1..3, mcp-server, keycloak.localhost`. Production: one per host, from a real CA |
| `truststore.p12` | **the JDK's public CAs + the lab CA**. Java apps use it as their whole truststore, so replacing it with only the lab CA would break api.anthropic.com |
| `Health.class` | the members' TLS healthcheck (below) |

**What's https now:**
- **The MCP server:** `SERVER_SSL_*` with `GF_MCP_TLS_ENFORCE_NON_LOCAL=true` and `SERVER_FORWARD_HEADERS_STRATEGY=none` (enforcement trusts the connection's own scheme and address, so no proxy headers may change them).
  - plain http → `400`
  - https without the CA → curl exit 60
  - https with `--cacert` → 401 (needs a token)
- **Keycloak:** `--https-port=18180 --http-enabled=false`. Its management port (health) stays http (`KC_HTTP_MANAGEMENT_SCHEME=http`).
- **GemFire's HTTP service** (Management REST, `/metrics`, developer REST): `ssl-enabled-components=web`. The MCP server reaches it at `https://locator:7070` with `GF_MCP_GEMFIRE_TRUSTSTORE_PATH`. Prometheus uses `scheme: https` + `ca_file`.

**The MCP server's startup log has no security warnings left.** Before 10c it had three:
- `gemfire.url … is plaintext and not loopback, allowed only because …allow-insecure-url=true`
- `issuer-uri … is plaintext and not loopback, allowed only because …allow-insecure-issuer=true`
- `Other machines can reach this server over plaintext HTTP…`

(With security off there's a fourth: `failure-limit.enabled=false: failed-authentication throttling and auditing are OFF`.)

**GemFire healthchecks.** The image has no curl or openssl, and bash's `/dev/tcp` can't speak TLS. `Health.java` (compiled once by the certs job) does an https GET as `monitor`:
- `java -Xmx24m -XX:TieredStopAtLevel=1 -cp /certs ... Health <url> <expected text>`
- cost: **0.24 s and ~0.3 s of CPU per run**, about 6% of a core per member at a 5 s interval

**Trusting the CA:**

| Client | How |
|---|---|
| scripts on the Mac | `curl --cacert data/certs/ca.pem` (`SEC_CURL` in `scripts/security.sh`) |
| SRE app, MCP server (Java) | `JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=/certs/truststore.p12 …`. The MCP server's OAuth settings have no truststore of their own |
| Inspector (Node, in Docker) | `NODE_EXTRA_CA_CERTS=/certs/ca.pem` |
| Claude Code (Node, on the Mac) | `eval "$(scripts/mcp-token.sh --env)"` **before** starting `claude`. It exports the https URL (`.mcp.json` reads `${GF_MCP_PUBLIC_URL:-http://localhost:8085/mcp}`) and `NODE_EXTRA_CA_CERTS`, which Node reads only at startup |
| Chrome (the Keycloak login page) | shows a certificate warning you can click through. To make it go away (optional; the CA can then sign anything your Mac trusts, so remove it when you're done): `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain data/certs/ca.pem` · remove: `sudo security remove-trusted-cert -d data/certs/ca.pem` |

**Still plaintext, on purpose:**
- GemFire client/server, peer-to-peer and locator traffic (`ssl-enabled-components=cluster,server,locator`: every member and client would need keystores; the workload's password crosses the Docker network in the clear)
- S3 to SeaweedFS
- the SRE app and Grafana on localhost

## Things we hit

1. **`make start` alone after switching** would recreate every member at once: quorum loss, locator deadlock (chunk 6). Always `make stop && make start`.
2. **Switching off left the servers secured** (they exited at startup): the cluster configuration remembers the `security-manager`. `make start` now resets it when the mode changes (see "How the switch works").
3. **Netty and `*.localhost`**, macOS's resolver, curl's Secure-cookie rule: see 10b.
4. **The MCP healthcheck flooded the audit** with `auth_failure` once the failure limit was back on. Moved to the protected-resource metadata path.
5. **Python 3.13 refused the first lab CA** (no key usage extension). `make-certs.sh` adds `ku:c=keyCertSign,cRLSign`.
6. **Keycloak imports the realm only on a new container** (`start-dev` keeps its database inside it). After editing `gfmcp-realm.json`: `docker compose up -d --force-recreate keycloak`.
7. **Session binding and log content via other tools:** see the findings in 10b.
