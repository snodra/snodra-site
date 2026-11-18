# Configuration

## Configuration (`Config::from_env`)

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVICE_NAME` | required | hub `service_name`, base of every processor's consumer group (`<service>.<processor>`, `default` included), event `source` |
| `SNODRA_MONGODB_URI` | required | must name a database, e.g. `mongodb://mongodb:27017/service-c?replicaSet=rs0` |
| `SNODRA_SERVER_ADDRESS` | `static://snodra-server:7000` | the hub's gRPC target (`static://` optional), a comma-separated list of them, or one `dns:///name:port` re-resolved every 30 s (see [Multiple hubs](api.md#multiple-hubs)); one target is the single-hub setup |
| `SNODRA_SERVER_STATUS_INTERVAL_MS` | 5000 | how often `InstanceStatus` goes to every hub (at least 1) |
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | |
| `SNODRA_KAFKA_TOPIC` | `kraken.events` | |
| `SNODRA_JWKS_URL`, `SNODRA_ISSUER` | unset | set both to verify forwarded tokens (RS256, `exp`, `iss`); unset = read signed tokens unverified, warned once |
| `SNODRA_SERVER_REQUEST_TIMEOUT_MS` | unset | default request timeout, sent as `timeout_ms` (`SendOptions.timeout` wins per call). Unset: the hub gets `timeout_ms = 0` and applies its per-type override or its default (5 s). `0` counts as unset (here and for `SendOptions.timeout`) |
| `SNODRA_RECONNECT_BACKOFF_MIN_MS` / `_MAX_MS` | 500 / 5000 | exponential, each wait ±20 % jitter and never above the max (at the max: 80-100 % of it); back to the min once a connect reached the handshake; the min and the max must each be at least 1 ms and the max not below the min (a startup error otherwise) |
| `SNODRA_MAX_CONCURRENT_HANDLERS` | 256 | handlers run at once, at least 1 (`0` is rejected at startup, also when set in code: `Config::validate`); also the permits offered to the hubs (`Register.initial_permits`), which queue further requests for this instance |
| `SNODRA_SERVER_LOAD_FACTOR` | 100 | `Register.load_factor`: relative capacity; weights this instance's share of keyed commands and its load score. A non-negative integer (a negative value is rejected at startup); `0` is sent as is and read as 100 by the hub |
| `SNODRA_SERVER_TAGS` | none | `Register.tags`, `k=v,k=v`: unkeyed requests prefer instances whose tags match more of the sender's tags |
| `SNODRA_SERVER_PRIORITIES` | none | default `Request.priority` per outgoing type, `type=n,type=n` (higher first while the target's queue at the hub is not empty); `SendOptions.priority` wins |
| `SNODRA_SERVER_RETRY_ENABLED` | false | caller-side retry of transient failures (see Retry): `true` sets `Config.hub_retry` to the policy the variables below describe, `false` leaves it `None` (no retry unless a call sets `SendOptions.retry`, which wins per call) |
| `SNODRA_SERVER_RETRY_MAX_ATTEMPTS` | 3 | attempts in total, the first included; at least 1 (`0` is rejected at startup, also while retry is disabled) |
| `SNODRA_SERVER_RETRY_INITIAL_BACKOFF_MS`, `_MULTIPLIER`, `_MAX_BACKOFF_MS` | 100, 2, 2000 | wait before the second attempt, growth factor (a finite number >= 1, else rejected at startup), cap of one wait; each wait is jittered by ±20 % and never above the cap (at the cap: 80-100 % of it), like the reconnect backoff |
| `SNODRA_SERVER_STREAM_CREDIT_TIMEOUT_MS` | 600000 | how long a streaming query handler waits for credit before it ends its stream with `TIMEOUT` "no credit within <d>" and releases its permits (see [Streaming queries](api.md#streaming-queries)); the default is the hub's default `SNODRA_SERVER_MAX_STREAM_DURATION` (10 min); at least 1 (`0` is rejected at startup, also when set in code) |
| `SNODRA_SERVER_MAX_SUBSCRIPTIONS` | 1024 | the most subscription queries this instance serves at once (see [Subscription queries](api.md#subscription-queries)): a subscription request beyond it is refused with `ReplyEnd{error = RESOURCE_EXHAUSTED}` `subscription limit (N) reached`, which the subscriber sees as `HandlerBusy`; subscriptions hold no handler permit, so this is their only bound here; the hub has its own per-instance limit (`SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE`, 1024); at least 1 (`0` is rejected at startup, also when set in code) |
| `SNODRA_SERVER_TOKEN` | none | the static access token sent in `Register.credentials.token` on every hub stream (`Config.hub_token`, a `SecretString` whose `Debug` prints `"***"`); needed when the hub runs `SNODRA_SERVER_AUTH_MODE=enforce`, ignored by a hub in `off` mode; an empty value is no token; never logged (see [Security](#security)) |
| `SNODRA_SERVER_TOKEN_FILE` | none | a file holding the token, for container secrets (`Config.hub_token_file`); read at startup (an unreadable file is a startup error) and again before every reconnect, so a rotated secret needs no restart; **wins over `SNODRA_SERVER_TOKEN` when both are set**; surrounding whitespace is trimmed, an empty file is no token at startup, and after a good read it keeps the last token |
| `SNODRA_SERVER_OAUTH2_TOKEN_URI` | none | turns JWT authentication on (`Config.hub_oauth2`): the Keycloak token endpoint, e.g. `https://keycloak/realms/snodra/protocol/openid-connect/token`; needs a client secret and excludes `SNODRA_SERVER_TOKEN` / `SNODRA_SERVER_TOKEN_FILE` (both set is a startup error); see [Authenticating with a JWT](#authenticating-with-a-jwt-keycloak-client-credentials) |
| `SNODRA_SERVER_OAUTH2_CLIENT_ID` | `SNODRA_SERVICE_NAME` | the Keycloak client id; it must be the service name (the hub checks the token's `azp` against it) |
| `SNODRA_SERVER_OAUTH2_CLIENT_SECRET`, `SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE` | none | the client secret (`SecretString`, never logged), or a file holding it, **which wins** and is re-read on every token fetch so a rotated secret applies without a restart; one of them is required with the token URI |
| `SNODRA_SERVER_OAUTH2_SCOPE`, `SNODRA_SERVER_OAUTH2_CA` | none | the `scope` sent with the grant (space-separated as sent); a PEM file with extra root certificates for an `https://` token endpoint, added to the platform roots (not the hub CA of `SNODRA_SERVER_TLS_CA`) |
| `SNODRA_SERVER_TLS` | `false` | `true` makes every hub channel TLS (`Config.hub_tls = Some(HubTls { .. })`), for a static list and for `dns:///`; needed when the hub sets `SNODRA_SERVER_TLS_CERT`. An `https://` address turns TLS on by itself (system roots) |
| `SNODRA_SERVER_TLS_CA` | none (system roots) | PEM file with the CA that signs the hub's certificate (`HubTls.ca_file`), re-read on every connect; needs `SNODRA_SERVER_TLS=true` |
| `SNODRA_SERVER_TLS_SERVER_NAME` | the host of the address (for `dns:///name:port`, `name`) | the name the hub's certificate must carry, also sent as SNI (`HubTls.server_name`); needs `SNODRA_SERVER_TLS=true` |
| `SNODRA_SERVER_TLS_CLIENT_CERT`, `SNODRA_SERVER_TLS_CLIENT_KEY` | none | the client certificate chain (leaf first) and its PKCS#8 PEM private key for mutual TLS (`HubTls.client_cert_file`, `HubTls.client_key_file`); both or neither; **they turn TLS on** like `SNODRA_SERVER_TLS=true` (`SNODRA_SERVER_TLS=false` next to them is an error); exclude `SNODRA_SERVER_TOKEN*` and `SNODRA_SERVER_OAUTH2_*` (one credential kind per service; a startup error naming both); the files are checked at startup. See [Authenticating with a client certificate](#authenticating-with-a-client-certificate-mtls) |
| `SNODRA_CONSUMER_ENABLED`, `SNODRA_CONSUMER_MAX_ATTEMPTS` | true, 5 | one consumer per [event processor](api.md#event-processors) with handlers (`default` also for sagas alone); the attempts and the 1 s backoff are shared by every processor |
| `SNODRA_KAFKA_DEAD_LETTER_MODE` | `collection` | where a record a processor cannot handle goes (see [Dead letters](dead-letters.md)): `collection` (`dead_letters`, sequenced per key, admin API), `topic` (`<topic>.dlt`) or `log` (logged and skipped); case-insensitive, anything else is a startup error |
| `SNODRA_KAFKA_DEAD_LETTER_RETENTION_MS` | 2592000000 (30 d) | how long a letter is kept (`expireAt` = `parkedAt` + this; a TTL index removes it then, which unblocks its key); at least 1000 (a startup error otherwise, also when set in code) |
| `SNODRA_OUTBOX_ENABLED`, `SNODRA_OUTBOX_POLL_INTERVAL_MS`, `SNODRA_OUTBOX_BATCH_SIZE`, `SNODRA_OUTBOX_MAX_ATTEMPTS` | true, 200, 100, 10 | |
| `SNODRA_FORWARD_JWT` | true | |

## Security

Access control and TLS for the hub connection (roadmap P5a, hub ADR 0018). Everything here is opt-in
and the hub decides: against a hub in `SNODRA_SERVER_AUTH_MODE=off` (the default) the token is ignored
and nothing changes.

**Token.** Set `SNODRA_SERVER_TOKEN` (or `Config.hub_token`) to the service's static token. It is sent in
`Register.credentials.token` of every stream to every hub, and nowhere else. It is never logged:
`Config`'s and `HubSettings`' `Debug` print `"***"`, and the error and log lines about it carry the
path or the code, not the value. An empty token is no token. Generate one per service with
`openssl rand -hex 32`; the hub's ACL holds only its SHA-256 (`snodra-server acl hash -`).

**Token file.** `SNODRA_SERVER_TOKEN_FILE` (or `Config.hub_token_file`) names a file with the token, the
way container secrets arrive (`/run/secrets/...`). It is read at startup (unreadable is a startup
error, `Config::validate`) and **again before every reconnect**: rotate the secret, and the next
attempt uses it, no restart. If both settings are set **the file wins**. If the file cannot be read
later (a secret mid-swap) the last token read from it is kept and a warning logged. The same holds
for a file that is **empty after a good read** (a non-atomic rotation caught between the truncate and
the write): the last good token is kept and one warning logged until a good read follows. At
startup an empty file still means no token. Prefer an atomic swap (write a new file, rename it over
the old one) all the same.

**Rejections.** In `enforce` mode the hub closes the stream of a service it refuses: `UNAUTHENTICATED`
(no token, an unknown token) or `PERMISSION_DENIED` (the token is for another service name, or the
`Register` lists a command, query or shared query type outside the token's `handle` patterns, which
the message names). A `Register` whose **instance id is held by a session of another service** is
also `PERMISSION_DENIED` (`instance id 0190abcd belongs to another service`); the hub refuses that in
`permissive` mode too, and the holder keeps its session, so give every instance a unique id (the
default is a random UUID). Like `ALREADY_EXISTS` and `INVALID_ARGUMENT` before, these are registration
rejections, not outages:

- `HubConnection::last_rejection()` holds the hub's message (until a stream registers, which clears
  it); `await_hub` / `await_all_hubs` keep returning `false` while the hub refuses, as for the
  other rejections.
- The reconnect waits the **backoff cap** (`reconnect_backoff_max`, 80-100 % of it), not the floor:
  no tight loop against a hub that will keep saying no.
- The log line `hub rejected the registration` is at `error` once per distinct (code, message),
  then at `debug` (it resets once a stream registers). Fix the token or the ACL; the next attempt
  succeeds on its own.

**Access denied.** A request whose type is outside the token's `send` patterns is answered by the hub
with `Error{PERMISSION_DENIED}` before anything is routed, in every mode. It surfaces as
`MessagingError::AccessDenied(message)` from `send_command`, `send_query`, `scatter_gather`,
`stream` and `subscribe`, and is **never retried** (`Config.hub_retry` does not apply). A handler
that returns `AccessDenied` replies `PERMISSION_DENIED`.

**TLS.** `SNODRA_SERVER_TLS=true` (`Config.hub_tls`) makes the channel TLS: rustls through tonic, the
`ring` provider like the hub, TLS 1.2 and 1.3, for every address form (a static list, `dns:///`; an
`https://` address turns it on by itself). Without `SNODRA_SERVER_TLS_CA` the platform's root certificates
are trusted; with it, that PEM file's CA is (re-read on every connect, so a CA rotation needs no
restart). `SNODRA_SERVER_TLS_SERVER_NAME` sets the name the certificate must carry and the SNI, for a
hub reached by an address that is not in its certificate. With `dns:///name:port` the certificate is
checked against **`name`** (the DNS host, not the `ip:port` it resolves to; as snodra-messaging does)
unless `SNODRA_SERVER_TLS_SERVER_NAME` is set, which wins; a static `host:port` is checked against its
host. If the application installs its own
process-wide rustls provider, tonic uses that one. For a client certificate (mutual TLS) see
[Authenticating with a client certificate](#authenticating-with-a-client-certificate-mtls).

A mismatch is a clear log line, not a hang: plain text to a TLS hub (which drops anything that is not
a TLS handshake) logs `hub stream closed; reconnecting ... set hub_tls / SNODRA_SERVER_TLS=true`, and TLS
to a plain-text hub or a certificate the CA does not vouch for logs `TLS to the hub failed: does it
serve TLS, and does its certificate match hub_tls ca_file and server_name?` with the cause.

```bash
SNODRA_SERVER_TOKEN_FILE=/run/secrets/orders-hub-token \
SNODRA_SERVER_TLS=true SNODRA_SERVER_TLS_CA=/etc/snodra/ca.pem SNODRA_SERVER_TLS_SERVER_NAME=snodra-server
```

### Authenticating with a JWT (Keycloak client credentials)

Instead of a static token a service can register with a short-lived Keycloak access token (roadmap
P5b, hub ADR 0019). In Keycloak, make the
service a **confidential client with service accounts only** (no standard flow, no direct access
grants) whose **client id is the service name**: the hub checks the token's `azp` against
`Register.service_name` and takes the rights from its `[[service]]` ACL table of that name. Then set

```bash
SNODRA_SERVER_OAUTH2_TOKEN_URI=https://keycloak/realms/snodra/protocol/openid-connect/token \
SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE=/run/secrets/orders-client-secret   # client id defaults to the service name
```

(`Config.hub_oauth2 = Some(HubOAuth2 { token_uri, client_id, client_secret, .. })` in code; the
variables are in the table above.) One `TokenProvider` per `SnodraMessaging` fetches the token with
the `client_credentials` grant (`client_secret_basic`: id and secret form-urlencoded, then base64,
RFC 6749 2.3.1; 10 s timeout; response capped at 1 MiB; `token_type` must be `Bearer`; a missing
`expires_in` means 60 s, with one warning) and every hub connection shares it: N hubs, one token,
one fetch, concurrent connects wait for it. A token is used while more than its margin remains
(20 % of its lifetime, at least 5 s, at most half of it) and is then replaced in the background,
not on demand; on every handshaken stream the new token is sent as `ClientMessage.credentials`, so
the session outlives the token (the hub closes a JWT session `SNODRA_SERVER_JWT_EXPIRY_GRACE`, 30 s,
after `exp` otherwise); a stream still waiting for its ack sends it right after the ack. A failed
background refresh keeps the current token and retries after 1 s, 2 s ... 30 s.

A token is fresh only while both the monotonic clock and the **wall clock** say more than its margin
remains (the monotonic clocks, `Instant` and tokio's timers, stand still while a laptop sleeps, so a
service waking after `exp` would otherwise keep serving its cached token), and the refresh loop wakes
at least every 5 s to look at the wall clock again. A stream the hub ends with `UNAUTHENTICATED` (a
`Register` or refresh refused, or a later close: "token expired", "unknown signing key", "credentials
expired") retires the access token it presented (its `Register`'s, or the last refresh it sent; a newer token fetched meanwhile is kept), so the next stream fetches a new one, paced by the normal reconnect backoff; `PERMISSION_DENIED`
(wrong `azp`, no ACL entry) does not, because a new token would not help and the IdP is not to be
hammered. `SnodraMessaging::shutdown()` closes the provider (`TokenProvider::close`): the refresh loop
ends and no further request reaches the IdP even if a `Sender` is still held.

If no token can be had (the endpoint answers 401 `invalid_client`, is unreachable or misbehaves) the
stream is **not opened**: `last_rejection()` reads `no access token for <service> (<instance>):
<what the endpoint said>` (clipped to 200 characters; distinguishable from a hub refusal), it is logged
at `error` once per distinct message and then at `debug`, and the attempt is retried with the normal
reconnect backoff, so a recovered endpoint is used at once. A hub that has not loaded its JWKS yet
answers `UNAVAILABLE` "jwks not loaded yet": an ordinary retry, not a logged rejection.

The client secret and the tokens never appear in logs, errors or `Debug` output (an endpoint that echoes the
`Authorization` header or the secret in its error text has them masked as `***`). For what is
running, `SnodraMessaging::hub_auth()` (also `HubPool::auth()`, `HubConnection::auth()`) gives the
`AuthKind` (`none`, `token`, `jwt`), the current token's expiry, the last token fetch error and
`token_fetches`, the fetch counts by result (`ok`, `http_error`, `oauth_error`, `io_error`,
`bad_response`; also `TokenProvider::stats()`); `hub_credentials_refreshes_sent()` counts the
refreshes written. This crate has no
metrics registry, so these counters stand in for `snodra_messaging_hub_token_fetches_total{result}`
and `snodra_messaging_hub_credentials_refreshes_sent_total`. A static token session whose
`SNODRA_SERVER_TOKEN_FILE` changes also sends a refresh (checked once per heartbeat) on its handshaken
streams, so a token rotation needs no reconnect.

`http://` token URIs are accepted (the sandbox uses `http://keycloak:8080`) with one warning unless the
host is loopback or a single-label name: the secret then crosses the network in the clear.

Differences from the Kotlin starter: the Rust configuration has no relaxed `SNODRA_MESSAGING_*`
binding (only `SNODRA_SERVER_OAUTH2_*`), no `/env` redaction layer to extend (`SecretString` prints
`"***"`), and no metrics registry (accessors above).

### Authenticating with a client certificate (mTLS)

A third credential (roadmap P5c, hub ADR 0020, "mTLS
mode" in [06-security.md](../../server/configuration/mtls.md)): the service presents a
certificate in the TLS handshake of the hub connection, and the hub reads the service's identity from
it. No secret crosses the wire and no identity provider is in the path. Set

```bash
SNODRA_SERVER_TLS_CLIENT_CERT=/etc/snodra/orders.pem \
SNODRA_SERVER_TLS_CLIENT_KEY=/etc/snodra/orders.key \
SNODRA_SERVER_TLS_CA=/etc/snodra/ca.pem            # the CA of the hub's certificate (see TLS above)
```

(`Config.hub_tls = Some(HubTls { client_cert_file, client_key_file, .. })` in code.) Setting them turns
TLS on, as `SNODRA_SERVER_TLS=true` does. The key is PKCS#8 PEM (`BEGIN PRIVATE KEY`, what `openssl req
-newkey` writes); EC (`BEGIN EC PRIVATE KEY`) and RSA PEM keys work as well, without a promise. A PKCS#8
EC key that lacks its public key (some tools write it that way) is refused at startup with the
conversion to run: `openssl pkcs8 -topk8 -nocrypt -in key.pem -out key.pkcs8.pem`, or generate a new
key with openssl.

**The SAN rule.** The leaf must carry **exactly one URI SAN `snodra://service/<name>`**, `<name>` being
the service name (`SNODRA_SERVICE_NAME`; 1 to 128 characters of `[A-Za-z0-9._-]`), and, if it has an
extended key usage at all, `clientAuth`. DNS names and other URIs on it are ignored; none, or two
service names (even equal ones), is `PERMISSION_DENIED` at the hub. The hub's `[[service]]` table of
that name gives the rights, as for a JWT. How to issue one (`openssl`, cert-manager) is in
[06-security.md](../../server/configuration/mtls.md).

**What is checked, and when.** At startup (`Config::validate`, so also `SnodraMessaging::builder`): both
files, no static token and no OAuth2 next to it, both files readable and holding a certificate and a
key, the key belonging to the leaf, the leaf naming exactly this service, the leaf not yet expired.
Each is a startup error that names the file and the problem (never the key). A certificate and a
static token or OAuth2 together would be refused by the hub (a stale credential next to a good
certificate), so the client sends **no credentials** with a certificate and refuses the combination.
Before every connect the pair is read again and checked the same way, so a renewed pair is used by the
next reconnect with no restart; files caught half way through a replacement (unreadable, empty)
keep the last good pair, with one warning, and so does every other problem with the files while that
pair has not expired (another service's pair, an expired one, one that is not valid yet): one `warn`
per problem. Without a good pair to fall back on, a pair for another service or an expired one fails
the attempt before a stream opens (a registration rejection: `last_rejection()`, one `error` line per
distinct message, retried at the backoff cap).

**Rotation.** The pool reads the files every 3 s (`HubSettings::certificate_check_interval`, as the
Kotlin client does, whatever the heartbeat period). When they hold a valid pair (not expired, and
past its `notBefore`: a pair that is not valid yet is waited for, never rolled to) that a live
connection is not presenting, it first waits a **random delay**, uniform in `[0, min(30 s, 10 % of the
shortest remaining validity among the connections that still present an older pair)]` (0 once that
certificate has ended; `certificate_roll_delay_max` sets the 30 s, 0 switches the delay off), drawn once
per renewed pair (not per hub), so that the replicas which see the
same renewal in the same tick do not all leave the routing together; it then reads the files again
(the roll goes to whatever pair is current then, with no second delay, and is skipped if no
connection is stale any more) and rolls the hubs over **one at a time**, in the
order of `hub_address`:

1. the hub is told the instance is stopping (a `Register` with no types, as the shutdown path does),
   so it routes new work to other instances; a hub that has another live hub is also taken out of
   this instance's own routing, so new requests go to the other hubs (the only hub is taken out once
   its handlers have finished);
2. it waits, at most 10 s, for the requests written to that hub and the handlers of its requests to
   finish. **The streaming queries and subscriptions this instance itself consumes are not waited
   for**: they end when their owners decide, not when work is done, so the roll cuts them (as
   it always did) and their consumer sees the loss (`HubConnectionLost`); resubscribe on that. A
   handler that outlives the 10 s is cut too;
3. it closes the stream gracefully (half-close, up to 2 s for the hub to finish its side; what the hub
   sends meanwhile, a late reply included, still reaches its caller);
4. the connection reconnects at once with the new pair, and only when it is registered again (at most
   30 s) is the next hub rolled.

**A deployment with a single hub has a short gap**: the only hub is out of the routing from the end of
step 2 until its new stream is registered (milliseconds to a few seconds). A send in that window
**waits for the new stream** within its own deadline (the call's timeout; 30 s at most when it has
none) instead of failing, whatever the retry policy; if the deadline passes first it fails with
`HubUnavailable`. Requests already written to the hub when its stream closes (the 10 s ran out) fail
like on any lost stream (`HubConnectionLost`); `hub_retry` covers them for idempotent calls. Only a
deployment with several hubs rolls over with no request failing or waiting at all. If the new pair
does not load (a rotation caught half way, a key that is not the certificate's, a certificate for
another service, an expired one) every connection keeps what it presents and the problem is logged at
`error`, once per distinct problem, once it is still there a period later. A hub that does not take
the new pair back in time stops the rollover (logged at `error`; the other hubs keep their old pair
until the files change again). Replace the key and the certificate together, and prefer an atomic
swap (write new files, rename them over the old ones).

**Expiry.** The hub closes a certificate session at the certificate's `notAfter` with `UNAUTHENTICATED`
"certificate expired" and no grace, a TLS session being fixed. A client that renews the files ahead
of `notAfter` never meets it (the rollover above). One that did not reconnects after the close (a normal
reconnect at the normal backoff, one `info` line, no rejection) with whatever the files hold: a renewed
pair registers; the expired one is not offered (`expired at ...`, logged at `error` once) and the
attempts back off. When the certificate in use has less than a tenth
of its lifetime (or 24 h, whichever is smaller) left and the files hold no other, one `warn` per
certificate says so.

**Status.** `SnodraMessaging::hub_auth()` (also `HubPool::auth()`, `HubConnection::auth()`) reports
`AuthKind::Certificate` (`"certificate"`) and `certificate: Some(CertificateStatus { service,
fingerprint, not_after, rotations })`: the first 8 hex characters of the SHA-256 of the leaf presented
(what the hub's logs and `/api/v1/topology` show), its `notAfter`, and how many times the presented certificate
changed since the first one. Logs name a certificate by that fingerprint and the service only; the
key is never read into a log, an error or a `Debug` print. This crate has no metrics registry
(accessors only).

**A client without a certificate against a `required` hub** fails at the transport, not as a
rejection: with TLS 1.3 the client learns that its certificate was refused only when the stream opens,
so the log reads `hub stream closed; reconnecting ... a hub that requires client certificates does that
to a client that presents none: set hub_tls client_cert_file and client_key_file`, and attempts back
off as for any outage, at `warn` then `debug`. A hub in `optional` mode takes the same client with a
token or JWT.

Differences from the Kotlin starter: the settings are `HubTls.client_cert_file` / `client_key_file`
(`SNODRA_SERVER_TLS_CLIENT_CERT` / `_KEY`) and there is no relaxed `SNODRA_MESSAGING_*` binding; rotation
is run by the `HubPool` (a `HubConnection` used on its own re-reads the files on reconnect only); the
rotation count is in `CertificateStatus` and there is no metrics registry.

**Turning it on: permissive first.** (1) Run the hub with `SNODRA_SERVER_AUTH_MODE=permissive` and the
ACL; it logs and counts every violation (`snodra_hub_auth_violations_total`) and refuses nothing;
(2) give the services their token (and TLS, once the hub has a certificate); (3) when the hub's log
and metric show no violation, switch it to `enforce`. A service without a token against an `enforce` hub is refused
and shows up as the `UNAUTHENTICATED` rejection above.

Tested in `tests/hub_auth.rs` and `tests/hub_tls.rs` against the in-process fake hub (which implements
the hub's modes and codes), and in `tests/e2e_auth.rs` against `snodra-server:dev` (`SNODRA_SERVER_IMAGE`)
running `enforce` with an ACL file and a TLS certificate generated at test time. JWT authentication is tested in
`tests/hub_jwt.rs` (a test OAuth2 token endpoint in `tests/support/idp.rs`, with ES256 keys generated
at test time, and the fake hub, which accepts a JWT without verifying it and records refreshes) and in `tests/e2e_jwt.rs` against `snodra-server:dev` (`SNODRA_SERVER_IMAGE`) in
`enforce` with a `[[service]]` ACL entry, 2 s expiry grace and no leeway: the JWKS is served to the
hub by a small container (the official `busybox` image's `httpd`) on the bridge network and tokens live 6 s, so the session
surviving past `exp` plus the grace proves the refresh.

Client certificates are tested in `tests/hub_mtls.rs` against the in-process fake hub, which verifies
client certificates against a CA generated at test time and records what each stream presented (the
rollover order, one hub at a time and deregistering first, the 10 s wait for handlers, a trickle of
requests with no failure across two hubs, invalid pairs, the expiry warning, no key material in logs),
and in `tests/e2e_mtls.rs` against `snodra-server:dev` in `enforce` with `SNODRA_SERVER_TLS_CLIENT_AUTH=required`
(two hubs for the rotation; a certificate that lives 8 s for the hub's `notAfter` close). The hub's own
server certificate is issued by the same CA with the client usage too, so its `--health-check`, which
presents the hub's own pair under `required`, stays healthy.
