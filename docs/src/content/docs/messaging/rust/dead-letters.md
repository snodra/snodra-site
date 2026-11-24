---
title: "Dead letters"
---

A record a processor cannot handle is kept, not lost. `SNODRA_KAFKA_DEAD_LETTER_MODE`
chooses where it goes:

| Mode | What happens | Sequenced per key | Admin API |
|---|---|---|---|
| `collection` (default) | parked in the `dead_letters` collection, then the offset is committed | yes | `app.dead_letters()` |
| `topic` | produced to `<topic>.dlt` (same key and value, the original headers plus `snodra-dlt-processor`, `snodra-dlt-reason`, `snodra-dlt-error` (`<type>: <message>`, at most 2000 characters), `snodra-dlt-original-topic`, `-partition`, `-offset`); the offset is committed once the broker acknowledged it. **The DLT must exist or broker auto-creation must be on** | no | none (the topic is the operator's) |
| `log` | logged and skipped | no | none |

**Reasons** (per processor, stage 1 only; saga failures keep `saga_failures`):

- `HANDLER_FAILED`: the processor's handlers failed on every attempt (`attempts` = the invocations
  made; one for a payload the type cannot be read from).
- `SEQUENCED`: the record's Kafka key has an earlier letter in this processor; it is parked
  without running the handlers (`blockedBy` names the key's head letter). **The sagas still see
  it.** A record without a key is never sequenced.
- `INVALID`: no `type` header, or a value that is not a JSON object for a type the processor
  handles. It blocks nothing and can only be discarded. A type no handler of the processor knows
  is skipped, not a letter.

**Guarantees.** A letter is a single insert outside any transaction, keyed
`<processor>:<topic>:<partition>:<offset>`, so a redelivered record is parked once. **The offset
is committed only after the letter exists**: when MongoDB refuses it the record stays
unacknowledged, its partition is sought back to it and the consumer polls on, so the record comes
again about every second (the processor turns FAILING; its partition's later records wait, the
other partitions flow, and the instance keeps its group membership however long the outage). The
redelivery parks it without running the handlers again (the failure is remembered while the
partition stays assigned). Sequencing keeps an in-memory set of the parked keys of the
partitions this instance holds (loaded on every assignment, added to on every park); a record
whose key is in the set is confirmed against the collection first, and a miss (another instance
retried or discarded the letters) removes the key and handles the record normally. **A letter that
expires** (`SNODRA_KAFKA_DEAD_LETTER_RETENTION_MS`, 30 d; TTL index on `expireAt`) **unblocks its
key**.

### The admin API

```rust
use snodra_messaging::processors::{RetryResult, DEFAULT_LIST_LIMIT};

let letters = app.dead_letters();
for letter in letters.list(Some("projections"), DEFAULT_LIST_LIMIT).await? { /* parkedAt, then _id */ }
let one = letters.get("projections:snodra.events:1:42").await?;           // Option<DeadLetterDocument>
let n = letters.count(None).await?;                                        // every processor
match letters.retry("projections:snodra.events:1:42").await? {
    RetryResult::Retried | RetryResult::Duplicate => {}                    // deleted
    RetryResult::Failed(message) => {}                                     // attempts + 1, kept
    RetryResult::Blocked(head_id) => {}                                    // retry or discard the head first
    RetryResult::NotRetriable | RetryResult::NotFound => {}                // INVALID / no such letter
}
let all = letters.retry_all("projections").await?;                         // RetryAllResult { retried, failed, blocked, skipped }
let gone = letters.discard("projections:snodra.events:1:43").await?;       // true when deleted
```

- **Any instance** of the service serves it, for the processors with handlers there (whether or
  not it consumes); a processor it does not run is an error naming it (`list(None, ..)` and
  `count(None)` cover every letter). In modes `topic` and `log` every call is an error naming the
  mode.
- **`retry` is exactly-once with respect to the handlers**: the processor's handlers for the type
  run in the marker transaction, and the letter's deletion is in the same transaction, so a
  failure leaves the letter (updated: `attempts + 1`, `error`, `lastAttemptAt`, reason
  `HANDLER_FAILED`, no `blockedBy`) and a crash can neither handle it twice nor handle it and keep
  it. One attempt per call, no back-off; the sagas are not re-run (they saw the record when it was
  parked). A marker that exists already is `Duplicate` (the letter is deleted). A letter whose type
  no handler of the processor handles any more is `Failed("no handler for <type> in processor
  <name>")`.
- **`retry_all`** goes per key in offset order (keys in their head letters' `parkedAt` order), a
  key stopping at its first failure (its later letters count as `blocked`), then the keyless
  letters in `parkedAt` order; INVALID letters are `skipped`.
- **`discard`** deletes a letter; discarding a key's head unblocks its next letter.

The document (the same from both libraries, contract fixtures in
`tests/fixtures/dead_letters_contract`): `_id`, `processor`, `topic`, `partition` (Int32), `offset`
(Int64), `key` (absent without one), `eventId`, `eventType` (absent when missing), `headers`,
`payload` (UTF-8 text) or `payloadBinary` (BinData, when not UTF-8; neither when empty), `reason`,
`error {type, message}`, `blockedBy` (SEQUENCED), `attempts` (Int32), `parkedAt`, `lastAttemptAt`,
`expireAt`, and `replay: true` when the record was parked while its processor replayed it (absent
otherwise; its retry is then a replay too). Indexes: `dead_letters_processor_key_offset`, `dead_letters_processor_parked`,
`dead_letters_expire` (TTL, `expireAfterSeconds: 0`).
