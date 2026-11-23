# Configuration

Every setting is an option (`snodra.Service`, `snodra.Hubs`, `snodra.MaxConcurrent`, ...). `snodra.FromEnv()` reads the
same `SNODRA_*` variables the other Snodra libraries read. Options apply in order, so one given after `FromEnv()`
overrides what the environment set. The same list is in the documentation of `FromEnv` (`go doc snodra.FromEnv`).

A variable that is unset, or blank, changes nothing. Numbers are non-negative integers; flags are `true`, `1`, `yes`,
`false`, `0` or `no`, in any letter case. A value that does not parse, or is out of range, makes `New` fail.

## Configuration (`snodra.FromEnv`)

| Variable | Option | Default | Meaning |
|---|---|---|---|
| `SNODRA_SERVICE_NAME` | `Service` | required | the hub `service_name`: the logical name of the service, for example `orders-service` |
| `SNODRA_INSTANCE_ID` | `Instance` | a random UUID | the instance id, unique per process (a pod name, for instance); a `Register` whose id is held by another service is refused |
| `SNODRA_SERVER_ADDRESS` | `Hubs` | `static://snodra-server:7000` | the hubs: a comma-separated list of `host:port` (a `static://`, `http://` or `https://` prefix is accepted), or one `dns:///name:port` whose every address is a hub, resolved again every 30 s; see [Several hubs](api.md#several-hubs) |
| `SNODRA_SERVER_STATUS_INTERVAL_MS` | `StatusInterval` | 5000 | how often every acknowledged hub gets an `InstanceStatus`, which also goes out at once whenever the acknowledged hubs change; at least 1 |
| `SNODRA_MAX_CONCURRENT_HANDLERS` | `MaxConcurrent` | 256 | handlers run at once, at least 1; also the permits offered to the hubs, which queue further requests for this instance |
| `SNODRA_RECONNECT_BACKOFF_MIN_MS`, `SNODRA_RECONNECT_BACKOFF_MAX_MS` | `ReconnectBackoff` | 500, 5000 | the wait between two attempts to reach a hub: the minimum, doubling up to the maximum, each wait jittered by +/-20 % and never above the maximum; back to the minimum once an attempt reached the `RegisterAck`; a refused `Register` waits 80 to 100 % of the maximum |
| `SNODRA_SERVER_LOAD_FACTOR` | `LoadFactor` | 100 | `Register.load_factor`: the instance's relative capacity; `0` reads as 100 |
| `SNODRA_SERVER_TAGS` | `Tags` | none | `Register.tags`, `key=value,key=value`: unkeyed requests prefer instances whose tags match more of the sender's |
| `SNODRA_SERVER_REQUEST_TIMEOUT_MS` | `DefaultTimeout` | none | the timeout of every `Send` and `Query` that sets none, sent as `Request.timeout_ms`; a per-call `Timeout` wins over it, and a context deadline that comes sooner caps it. With none, the hub applies its per-type override or its default (5 s); `0` is none |
| `SNODRA_SERVER_PRIORITIES` | `Priorities` | none | the default `Request.priority` per sent type, `type=n,type=n` (higher first while the target's queue at the hub is not empty); a per-call `Priority` wins |
| `SNODRA_SERVER_RETRY_ENABLED` | `DefaultRetry` | false | `true` sets the default retry policy from the four variables below; `false` leaves no retry unless a call sets `Retry`, which wins per call |
| `SNODRA_SERVER_RETRY_MAX_ATTEMPTS` | `RetryPolicy.MaxAttempts` | 3 | attempts in all, the first included; at least 1 (1 is no retry) |
| `SNODRA_SERVER_RETRY_INITIAL_BACKOFF_MS`, `SNODRA_SERVER_RETRY_MULTIPLIER`, `SNODRA_SERVER_RETRY_MAX_BACKOFF_MS` | `RetryPolicy` | 100, 2, 2000 | the wait before the second attempt, the growth factor (a finite number of at least 1) and the cap of one wait; each wait is jittered by +/-20 % and never above the cap. The policy variables are checked even while retry is off |
| `SNODRA_SERVER_STREAM_CREDIT_TIMEOUT_MS` | `StreamCreditTimeout` | 600000 | how long a streaming handler waits for the caller's credit before the stream ends with `TIMEOUT` and the handler's context is cancelled (the default is the hub's default maximum stream duration, 10 min); at least 1 |
| `SNODRA_SERVER_MAX_SUBSCRIPTIONS` | `MaxSubscriptions` | 1024 | the most subscription queries this instance serves at once; one more is refused with `RESOURCE_EXHAUSTED`; at least 1 |
| `SNODRA_JWKS_URL`, `SNODRA_ISSUER` | `JWKS` | unset | set both to verify forwarded tokens (RS256 signature, issuer, expiry); the issuer is required with the URL. Unset: no token is an identity (every caller is anonymous), a guarded handler cannot be registered, and a warning is logged once |
| `SNODRA_SECURITY_ROLES_CLAIM` | `RolesClaim` | `roles` | where a token's roles are read: a dotted path to a list of strings (`realm_access.roles`, `groups`), or `scope` for the space-separated scopes |
| `SNODRA_SERVER_ALWAYS_ROUTE_THROUGH_HUB` | `AlwaysRouteThroughHub` | false | `true` sends every `Send` and `Query` through a hub, also one of a type this instance handles itself; `false` answers a command, or a query that is not shared, of an own type in-process ([API](api.md#requests-answered-in-process)) |
| `SNODRA_FORWARD_JWT` | `ForwardJWT` | true | whether a request sent while handling one carries the handled request's token, so that the downstream handler acts for the same user |
| `SNODRA_SERVER_TOKEN` | `Token` | none | the static access token sent in `Register.credentials.token` on every hub stream; needed when the hub enforces access control; never logged |
| `SNODRA_SERVER_TOKEN_FILE` | `TokenFile` | none | a file holding the token, for mounted secrets; **wins over `SNODRA_SERVER_TOKEN`**; surrounding blanks are ignored; read again before every connection and on every heartbeat, so a rotated secret needs no restart |
| `SNODRA_SERVER_OAUTH2_TOKEN_URI` | `JWT` with `NewClientCredentials` | none | turns JWT authentication on: the provider's token endpoint; needs a client secret; see [Authenticating with a JWT](#authenticating-with-a-jwt) |
| `SNODRA_SERVER_OAUTH2_CLIENT_ID` | `ClientCredentials.ClientID` | the service name | the OAuth2 client id; it must be the service name (the hub checks the token's `azp` against it) |
| `SNODRA_SERVER_OAUTH2_CLIENT_SECRET`, `SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE` | `ClientCredentials.ClientSecret`, `.ClientSecretFile` | none | the client secret, or a file holding it, **which wins** and is read at every token fetch; one of them is required with the token URI |
| `SNODRA_SERVER_OAUTH2_SCOPE`, `SNODRA_SERVER_OAUTH2_CA` | `ClientCredentials.Scope`, `.CAFile` | none | the `scope` sent with the grant (space-separated); a PEM file of extra root certificates for the token endpoint, beside the system's |
| `SNODRA_SERVER_TLS` | `TLS` | false | `true` makes every hub connection TLS (1.2 or later); needed when the hub serves TLS. An `https://` hub address implies TLS with the system's roots |
| `SNODRA_SERVER_TLS_CA` | `TLSConfig.CAFile` | system roots | PEM file with the CA that signs the hubs' certificates, read again at every connection; needs `SNODRA_SERVER_TLS=true` |
| `SNODRA_SERVER_TLS_SERVER_NAME` | `TLSConfig.ServerName` | the host of each hub address | the name the hubs' certificates must carry, also sent as SNI; needs `SNODRA_SERVER_TLS=true` |
| `SNODRA_SERVER_TLS_CLIENT_CERT`, `SNODRA_SERVER_TLS_CLIENT_KEY` | `ClientCertificate` | none | the client certificate chain (leaf first) and its private key, PEM, for mutual TLS; both or neither; **they turn TLS on** (`SNODRA_SERVER_TLS=false` next to them is an error); see [Authenticating with a client certificate](#authenticating-with-a-client-certificate-mtls) |

Options with no variable: `Codec` (the payload codec, JSON by default), `Logger` (a `*slog.Logger`, `slog.Default`
by default), `Telemetry` (see [API](api.md#telemetry)) and, per call, `Timeout`, `Retry`, `NoRetry`, `RoutingKey`,
`Priority`, `Header`, `InitialCredit` and `MaxResults`.

## Credentials

At most one kind of credential is used: a token, a JWT, or a client certificate. Setting two kinds is an error at
`New`. Everything here is opt-in and the hub decides: against a hub whose access control is off, the credentials are
ignored.

### Token

`snodra.Token` (or `SNODRA_SERVER_TOKEN`) sets the service's static token, sent in `Register.credentials.token` of
every stream to every hub and nowhere else. A blank token is none.

`snodra.TokenFile` (or `SNODRA_SERVER_TOKEN_FILE`) names a file holding the token, the way container secrets arrive
(`/run/secrets/...`). `New` fails when the file cannot be read or is empty. Later it is read again before every
connection and on every heartbeat of a registered stream; a changed token is sent to the hub as a credentials refresh.
A file that cannot be read or is empty later (a rotation caught half way) keeps the last token read. Prefer an atomic
swap: write a new file and rename it over the old one.

### Authenticating with a JWT

`snodra.JWT` registers the instance with an access token from a `TokenSource`; `snodra.NewClientCredentials` is the
usual source, an OAuth2 client-credentials grant (the client is authenticated with HTTP Basic, the request takes 10 s
at most and follows no redirect):

```go
app, err := snodra.New(
	snodra.Service("orders-service"),
	snodra.Hubs("https://hub.example.test:7000"), // https:// implies TLS
	snodra.JWT(snodra.NewClientCredentials(snodra.ClientCredentials{
		TokenURL:         "https://idp.example.test/oauth2/token",
		ClientSecretFile: "/run/secrets/orders-service-secret",
	})),
)
```

- The token is renewed before it expires: when a margin of a fifth of its lifetime is left, at least 5 s and at most
  half the lifetime (so at 80 % of a long lifetime, and at half of a 10 s one). A new token is sent once on every
  registered stream as a credentials refresh.
- A failed renewal keeps the token and is retried after 1 s, doubling up to 30 s.
- A stream the hub closes with `UNAUTHENTICATED` drops the token it presented, so the next one registers with a new
  token; `PERMISSION_DENIED` keeps it.
- When no token can be had, no stream is opened: the failure is the latest `App.Rejection` and the attempt is retried at
  the reconnect backoff.

### Authenticating with a client certificate (mTLS)

`snodra.ClientCertificate(certFile, keyFile)` makes the instance present a client certificate to the hubs. The leaf
must carry exactly one URI SAN `snodra://service/<name>` naming the service; `New` checks the pair. The files are read
at every connection and every 3 s: a renewed valid pair is rolled over to before the presented certificate expires,
one hub at a time, after a short random delay. A pair that cannot be used keeps the one presented.

### Credentials in logs

`AccessToken` and `ClientCredentials` hide their secrets when printed with `%v`, `%+v`, `%#v` or `%s`, and in
`log/slog`. Two things are not covered: `%p` and `%w`, which `fmt` rejects as bad verbs for these types and `go vet`
flags, and `encoding/json`, whose `json.Marshal` writes the exported secret fields (`AccessToken.Value`,
`ClientCredentials.ClientSecret`). Do not marshal these values.

### Rejections

A hub that refuses a `Register` (`ALREADY_EXISTS` for a type another service owns, `INVALID_ARGUMENT`,
`UNAUTHENTICATED`, `PERMISSION_DENIED`) is not an outage: the instance keeps running and retries at the backoff cap
(80 to 100 % of the maximum). `App.Rejection` returns the latest refusal and is not cleared by a later acceptance. Fix
the token or the access rules and the next attempt succeeds on its own.

## Verifying forwarded tokens

With `snodra.JWKS` (or `SNODRA_JWKS_URL` and `SNODRA_ISSUER`) every forwarded token is checked, before a handler runs,
for its RS256 signature against the issuer's keys, its issuer and its expiry; a token that fails is answered
`UNAUTHENTICATED`, also when the keys cannot be fetched. Without it, no token is an identity: every caller is
anonymous, the token only goes on with the requests the handler sends, and registering a handler with a guard
(`RequireAuthenticated`, `RequireRole`, `RequireCaller`) is an error that also fails `Start` and `Run`. A header that is
not a bearer token, or a token that is not a signed JWS (unreadable, `alg: none`, an empty signature, an encrypted
token), is answered `UNAUTHENTICATED` with or without a JWKS.
