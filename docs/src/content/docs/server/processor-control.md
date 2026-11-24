---
title: "Processor control"
---

Pause, resume, reset and replay processors, and work their dead letters, from the dashboard or the API.

## Processor control

The hub is a stateless
control plane: it asks the instances that run a processor to act and turns their answers into one HTTP answer. The
state lives in each service's MongoDB (`processor_control`, one document per processor), which every instance reads at
start and every 5 s: a pause outlives every hub and reaches instances that start later. For control the hub reads no
Kafka and no MongoDB and sees no payload.

- **Who is asked.** Every live session of the service whose latest status lists the processor.
- **Pause, resume** go to all of them; the answer comes when every one answered or `SNODRA_SERVER_CONTROL_TIMEOUT` passed.
- **Reset** is a leased operation: every instance is prepared (leaves its consumer group, holds the processor's lock
  for a 30 s lease, renewed every 10 s while the reset runs), the prepared instance with the freshest status executes
  (resolves the target, runs the `@ResetHandler`s, deletes the processor's markers in the replay range, commits the
  offsets; at most `SNODRA_SERVER_RESET_TIMEOUT`), and every prepared instance is finished (aborted when the execute
  failed) and consumes again, still paused if it was. A reset is refused up front while this hub runs a reset of
  the same processor. A
  hub that dies mid-way stops renewing: the leases expire and the instances resume by themselves. The finish is sent
  only once the renewals in flight are answered (at most `SNODRA_SERVER_CONTROL_TIMEOUT`), and an instance refuses a
  renewal that still reaches it after its finish (`NOT_PREPARED`): a late renewal never takes the lock again.
- **A refused execute is not always "nothing changed".** Refusals before the reset handlers (`INVALID`,
  `GROUP_NOT_EMPTY` on the members check) changed nothing. After them (a reset handler failed, the executor's lease was
  lost, a MongoDB or Kafka error, Kafka refusing the commit) the handlers' effects stay, and the instance's message says
  what else changed, e.g. `reset handlers ran (2), 37 markers deleted, offsets not moved: retry the reset`. An execute
  that times out (`504`) or whose instance left (`502`) may still finish, or may already have run reset handlers or
  deleted markers: its `error.message` says so; check the processor before resetting again.
- **Dead letters** are listed, retried and discarded by the instance with the freshest status.
- **Several hubs:** every instance is connected to every hub, so one hub reaches all of them; the dashboard sends its
  controls to the hub that served the page. Two hubs or operators racing on one processor: one reset wins, the other is
  refused (`LOCKED`, 409) and aborted.

### Routes

Under `/api/v1/services/{service}/processors/{processor}/` (the dashboard API: CORS for the peers, `POST` and `DELETE`
included; gone with `SNODRA_SERVER_DASHBOARD_ENABLED=false`):

| Method and path | Credential | Body | Does |
|---|---|---|---|
| `POST pause`, `POST resume` | write | none | pause or resume on every instance that reports the processor |
| `POST reset` | write | `{"to":"earliest"}`, `{"to":"latest"}`, `{"to":{"timestampMs":n}}` or `{"to":{"offsets":[{"partition":0,"offset":12}]}}`; at most 4 KiB and 1024 offsets | the leased reset |
| `GET dead-letters?limit=n` | read | | the oldest `n` letters (default 50, clamped to 1..100) and the total |
| `POST dead-letters/{id}/retry` | write | none | retry one letter |
| `POST dead-letters/retry-all` | write | none | retry every letter of the processor |
| `DELETE dead-letters/{id}` | write | none | discard one letter |

**Credentials.** *Write*: `Authorization: Bearer <credential>` with the write token (`SNODRA_SERVER_DASHBOARD_WRITE_TOKEN`,
compared in constant time against its digest) or a credential the `Register` path accepts (a static ACL token; a JWT
when JWT credentials are configured) whose ACL entry has `control = true`. With no write token and no ACL entry with
`control = true` (never in auth mode `off`), every write answers `403 {"error":"controls are disabled"}`. The dashboard
token never writes (403, "read-only"). *Read*: as every `/api/v1/` read, the dashboard token when one is set, and the
write token reads too.

**Status codes.** `200` done; `400` a bad body, limit or letter id (or the instance said `INVALID`); `401` no credential
or an unknown one (bare, like the dashboard token's); `403` a credential without the right, the dashboard token, or
controls disabled; `404` an unknown service or processor (no live instance reports it), or a letter that does not
exist; `409` locked, refused (`LOCKED`, `NOT_PREPARED`, `GROUP_NOT_EMPTY`, `RESET_HANDLER_FAILED`), a retry `Blocked`
or `NotRetriable`, or a reset of the processor already running on this hub; `502` an instance failed (`FAILED`), left
before it answered, could not be sent the request, or (pause) none confirmed; `504` no answer in time. Errors answer
`{"error":"<why>"}`, and when an instance's answer decided it also `instanceId`, `result`, `code`, `message`. A
reset's `409`/`502`/`504` is its report (`outcome` `aborted` or `failed`) with `error` (see "A refused execute" above).

An instance's answer, wherever it appears: `{"result":"ok"|"refused"|"timeout"|"left"|"unsent"|"unexpected",
"code":"LOCKED"|...|null,"message":"..."}`.

```json
// POST .../pause  (200)
{ "service": "service-b", "processor": "audit", "action": "pause", "acknowledged": 2, "failed": 0,
  "instances": [ { "instanceId": "b-1", "result": "ok", "code": null, "message": "" },
                 { "instanceId": "b-2", "result": "ok", "code": null, "message": "" } ] }

// POST .../reset  {"to":"earliest"}  (200; 409, 502 or 504 with "outcome": "aborted" or "failed" and "error")
{ "service": "service-b", "processor": "audit", "action": "reset",
  "operationId": "0f3c9a1e-7d2b-4c1a-9e8f-5a6b7c8d9e0f", "target": { "to": "earliest" },
  "outcome": "ok", "executedBy": "b-2", "replay": true,
  "ranges": [ { "partition": 0, "from": 0, "until": 42 } ], "markersDeleted": 3, "resetHandlers": 1, "error": null,
  "instances": [
    { "instanceId": "b-1", "prepare": { "result": "ok", "code": null, "message": "" },
      "finish": { "result": "ok", "code": null, "message": "" } },
    { "instanceId": "b-2", "prepare": { "result": "ok", "code": null, "message": "" },
      "finish": { "result": "ok", "code": null, "message": "" } } ] }

// a reset another operation holds  (409)
{ ..., "outcome": "aborted", "executedBy": null,
  "error": { "stage": "prepare", "instanceId": "b-2", "result": "refused", "code": "LOCKED",
             "message": "held by operation 7f00..." }, ... }

// GET .../dead-letters?limit=50  (200)
{ "service": "service-b", "processor": "audit", "instanceId": "b-1", "total": 3,
  "letters": [ { "id": "audit:snodra.events:1:141", "processor": "audit", "topic": "snodra.events",
                 "partition": 1, "offset": 141, "key": "order-7", "eventId": "...", "eventType": "examples.OrderPlaced",
                 "reason": "HANDLER_FAILED", "errorType": "IllegalStateException", "errorMessage": "boom",
                 "blockedBy": "", "attempts": 3, "parkedAtMs": 1762250000000, "lastAttemptAtMs": 1762250001000 } ] }

// POST .../dead-letters/{id}/retry  (200; Blocked or NotRetriable 409, NotFound 404, same body)
{ "service": "service-b", "processor": "audit", "instanceId": "b-1", "letterId": "audit:snodra.events:1:141",
  "result": "Retried", "detail": "" }

// POST .../dead-letters/retry-all  (200)
{ "service": "service-b", "processor": "audit", "instanceId": "b-1", "retried": 2, "failed": 0, "blocked": 1, "skipped": 0 }

// DELETE .../dead-letters/{id}  (200; a missing letter 404)
{ "service": "service-b", "processor": "audit", "instanceId": "b-1", "letterId": "audit:snodra.events:1:141", "discarded": true }
```

`Failed` from a retry is a 200: the retry ran and the handler threw again (`detail` says what); the letter stays. A
pause answers 200 when at least one instance persisted it. Replies are bounded like a status: texts at 512 bytes, ids
and keys at 128, types at 256, at most 100 letters and 1024 ranges.

### Examples

```bash
W="Authorization: Bearer $SNODRA_SERVER_DASHBOARD_WRITE_TOKEN"
HUB=http://localhost:7001/api/v1/services/service-b/processors/audit
curl -s -X POST -H "$W" "$HUB/pause"
curl -s -X POST -H "$W" "$HUB/resume"
curl -s -X POST -H "$W" -H 'Content-Type: application/json' -d '{"to":"earliest"}' "$HUB/reset"
curl -s -X POST -H "$W" -H 'Content-Type: application/json' -d '{"to":{"timestampMs":1762250000000}}' "$HUB/reset"
curl -s -X POST -H "$W" -H 'Content-Type: application/json' \
  -d '{"to":{"offsets":[{"partition":0,"offset":120},{"partition":1,"offset":98}]}}' "$HUB/reset"
curl -s -H "Authorization: Bearer $SNODRA_SERVER_DASHBOARD_TOKEN" "$HUB/dead-letters?limit=20"
curl -s -X POST -H "$W" "$HUB/dead-letters/audit:snodra.events:1:141/retry"
curl -s -X POST -H "$W" "$HUB/dead-letters/retry-all"
curl -s -X DELETE -H "$W" "$HUB/dead-letters/audit:snodra.events:1:141"
```

With an ACL credential instead of the write token, its entry needs `control = true`:

```toml
[[token]]
token_sha256 = "<digest>"
service = "ops-console"
control = true
```

### Dashboard

The Processors and Dead letters pages show the controls only while the tab holds a write credential: a second password
field, "Write token", kept in `sessionStorage` (this tab only, its own key, never in a URL) and sent as a header on the
control calls only. Pause and Resume act at once; Reset opens a dialog that names the service and the processor, says
that every instance leaves its consumer group until the reset ends and that a replay re-runs the processor's event
handlers (sagas and `@DisallowReplay` handlers excepted, after its `@ResetHandler`s), and takes the target (earliest,
latest, a time, or `partition:offset` pairs). Discard asks for confirmation. A refused call shows its reason and never
signs the page out. With peers, a control goes to the hub that served the page: it reaches every instance.

### Audit and metrics

One `info` line per call that passed the credential check (`control`, see [Observability](/docs/server/observability/)), and
`snodra_server_control_total{action,outcome}` for every call, refused credentials included (those are counted, not
logged). `snodra_server_control_unknown_replies_total` counts replies nobody waited for.
