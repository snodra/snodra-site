-- snodra-messaging message store, schema version 1 (PostgreSQL 13 or later).
-- Shared by the Kotlin add-on (snodra-messaging-jdbc) and the Rust one (snodra-messaging-sqlx): both read and write these
-- tables the same way. Idempotent: it can run again over itself. Frozen once released: later changes are V2, V3, ...
-- Times are UTC instants at millisecond precision, stamped by the application (never now()).
-- Identifiers and positions use the "C" collation: compared and ordered by their bytes.
-- *_hash columns hold the lowercase hex SHA-256 of a value's UTF-8 bytes: they carry the uniqueness and the lookups of values
-- with no length bound (marker ids, idempotency keys, start keys, record keys, associations); the value itself is in a
-- TEXT column next to it. Bounded columns are checked by the libraries before any write (see the module README).

CREATE TABLE IF NOT EXISTS snodra_schema (
    version    INTEGER        NOT NULL PRIMARY KEY,
    applied_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- The outbox (ADR 0005): events appended in the service's transaction, relayed to the event store afterwards.
CREATE TABLE IF NOT EXISTS snodra_outbox (
    id          VARCHAR(255) COLLATE "C" NOT NULL PRIMARY KEY,
    type        VARCHAR(255) COLLATE "C" NOT NULL,
    event_key   TEXT           NULL,
    headers     JSONB          NOT NULL,
    payload     JSONB          NOT NULL,
    created_at  TIMESTAMPTZ(3) NOT NULL,
    seq         BIGINT         NOT NULL,
    attempts    INTEGER        NOT NULL DEFAULT 0,
    sent_at     TIMESTAMPTZ(3) NULL,
    failed_at   TIMESTAMPTZ(3) NULL,
    last_error  TEXT           NULL,
    owner       TEXT           NULL,
    lease_until TIMESTAMPTZ(3) NULL
);
CREATE INDEX IF NOT EXISTS snodra_outbox_pending ON snodra_outbox (created_at, seq) WHERE sent_at IS NULL AND failed_at IS NULL;
CREATE INDEX IF NOT EXISTS snodra_outbox_sent ON snodra_outbox (sent_at) WHERE sent_at IS NOT NULL;

-- Processed-event markers: one per id (processor:<name>:<eventId>, saga:<type>:<eventId>, ingress:<source>:<key>, ...).
-- A stage-1 marker also carries its processor, source, segment and position (position_num: the position as a number when
-- it is a canonical decimal one, so a reset deletes a range by value).
CREATE TABLE IF NOT EXISTS snodra_processed_events (
    id_hash      CHAR(64) COLLATE "C" NOT NULL PRIMARY KEY,
    id           TEXT           NOT NULL,
    type         TEXT           NOT NULL,
    processed_at TIMESTAMPTZ(3) NOT NULL,
    processor    VARCHAR(64)  COLLATE "C" NULL,
    source       VARCHAR(255) COLLATE "C" NULL,
    segment      VARCHAR(128) COLLATE "C" NULL,
    position     VARCHAR(128) COLLATE "C" NULL,
    position_num BIGINT         NULL
);
CREATE INDEX IF NOT EXISTS snodra_processed_events_range ON snodra_processed_events (processor, source, segment, position_num) WHERE processor IS NOT NULL;
CREATE INDEX IF NOT EXISTS snodra_processed_events_processed_at ON snodra_processed_events (processed_at);

-- Dead letters (ADR 0022), sequenced per (processor, key). id = <processor>:<source>:<segment>:<position> (at most 578).
CREATE TABLE IF NOT EXISTS snodra_dead_letters (
    id              VARCHAR(578) COLLATE "C" NOT NULL PRIMARY KEY,
    processor       VARCHAR(64)  COLLATE "C" NOT NULL,
    source          VARCHAR(255) COLLATE "C" NOT NULL,
    segment         VARCHAR(128) COLLATE "C" NOT NULL,
    position        VARCHAR(128) COLLATE "C" NOT NULL,
    position_num    BIGINT         NULL,
    event_key       TEXT           NULL,
    event_key_hash  CHAR(64) COLLATE "C" NULL,
    event_id        TEXT           NULL,
    event_type      TEXT           NULL,
    headers         JSONB          NOT NULL,
    payload         TEXT           NULL,
    payload_binary  BYTEA          NULL,
    reason          VARCHAR(32)    NOT NULL,
    error_type      TEXT           NOT NULL,
    error_message   TEXT           NOT NULL,
    blocked_by      TEXT           NULL,
    attempts        INTEGER        NOT NULL,
    parked_at       TIMESTAMPTZ(3) NOT NULL,
    last_attempt_at TIMESTAMPTZ(3) NOT NULL,
    expire_at       TIMESTAMPTZ(3) NOT NULL,
    replay          BOOLEAN        NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS snodra_dead_letters_key ON snodra_dead_letters (processor, event_key_hash, position_num);
CREATE INDEX IF NOT EXISTS snodra_dead_letters_parked ON snodra_dead_letters (processor, parked_at);
CREATE INDEX IF NOT EXISTS snodra_dead_letters_expire ON snodra_dead_letters (expire_at);

-- One row per event processor (P6b, ADR 0023): its pause, the reset operation holding its lock, its open replay ranges
-- (a JSON array of {"source","segment","from","until"} strings, in order).
CREATE TABLE IF NOT EXISTS snodra_processor_control (
    processor      VARCHAR(64) COLLATE "C" NOT NULL PRIMARY KEY,
    paused         BOOLEAN        NOT NULL DEFAULT FALSE,
    paused_at      TIMESTAMPTZ(3) NULL,
    paused_by      TEXT           NULL,
    op_id          TEXT           NULL,
    op_kind        TEXT           NULL,
    op_lease_until TIMESTAMPTZ(3) NULL,
    op_prepared_at TIMESTAMPTZ(3) NULL,
    replay         JSONB          NOT NULL,
    updated_at     TIMESTAMPTZ(3) NULL
);

-- Idempotent external calls and ingress (@IdempotentHandler): one record per idempotency key (id). reply and error are JSON
-- text, kept as written.
CREATE TABLE IF NOT EXISTS snodra_external_calls (
    id_hash     CHAR(64) COLLATE "C" NOT NULL PRIMARY KEY,
    id          TEXT           NOT NULL,
    status      VARCHAR(32)    NOT NULL,
    reply       TEXT           NULL,
    error       TEXT           NULL,
    attempts    INTEGER        NOT NULL,
    updated_at  TIMESTAMPTZ(3) NOT NULL,
    lease_until TIMESTAMPTZ(3) NULL,
    owner       TEXT           NULL
);
CREATE INDEX IF NOT EXISTS snodra_external_calls_updated ON snodra_external_calls (updated_at);

-- Saga instances (ADR 0021). state is the saga as JSON text, kept as written. live_start_key_hash is the start key's hash
-- while the saga is live: its unique index lets one live saga hold a start key.
CREATE TABLE IF NOT EXISTS snodra_sagas (
    id                  VARCHAR(255) COLLATE "C" NOT NULL PRIMARY KEY,
    type                VARCHAR(255) COLLATE "C" NOT NULL,
    state               TEXT           NOT NULL,
    start_key           TEXT           NULL,
    start_key_hash      CHAR(64) COLLATE "C" NULL,
    ended               BOOLEAN        NOT NULL,
    ended_at            TIMESTAMPTZ(3) NULL,
    version             BIGINT         NOT NULL,
    created_at          TIMESTAMPTZ(3) NOT NULL,
    updated_at          TIMESTAMPTZ(3) NOT NULL,
    live_start_key_hash CHAR(64) COLLATE "C" GENERATED ALWAYS AS (CASE WHEN ended THEN NULL ELSE start_key_hash END) STORED
);
CREATE UNIQUE INDEX IF NOT EXISTS snodra_sagas_live_start_key ON snodra_sagas (live_start_key_hash);
CREATE INDEX IF NOT EXISTS snodra_sagas_type_ended ON snodra_sagas (type, ended);
CREATE INDEX IF NOT EXISTS snodra_sagas_ended_at ON snodra_sagas (ended_at);

-- A saga's associations key = value, in order (idx from 0): what routes events to it. assoc_hash = SHA-256 of
-- key, a zero byte, value.
CREATE TABLE IF NOT EXISTS snodra_saga_associations (
    saga_id     VARCHAR(255) COLLATE "C" NOT NULL REFERENCES snodra_sagas (id) ON DELETE CASCADE,
    idx         INTEGER  NOT NULL,
    assoc_key   TEXT     NOT NULL,
    assoc_value TEXT     NOT NULL,
    assoc_hash  CHAR(64) COLLATE "C" NOT NULL,
    PRIMARY KEY (saga_id, idx)
);
CREATE INDEX IF NOT EXISTS snodra_saga_associations_hash ON snodra_saga_associations (assoc_hash);

-- The saga-side outbox: commands and events a saga recorded, sent in seq order per saga.
CREATE TABLE IF NOT EXISTS snodra_saga_dispatch (
    id              VARCHAR(255) COLLATE "C" NOT NULL PRIMARY KEY,
    saga_id         VARCHAR(255) COLLATE "C" NOT NULL,
    seq             BIGINT         NOT NULL,
    kind            VARCHAR(16)    NOT NULL,
    type            VARCHAR(255) COLLATE "C" NOT NULL,
    payload         TEXT           NOT NULL,
    headers         JSONB          NOT NULL,
    routing_key     TEXT           NULL,
    created_at      TIMESTAMPTZ(3) NOT NULL,
    dispatched_at   TIMESTAMPTZ(3) NULL,
    attempts        INTEGER        NOT NULL,
    next_attempt_at TIMESTAMPTZ(3) NULL,
    failed_at       TIMESTAMPTZ(3) NULL,
    failure_reason  VARCHAR(32)    NULL,
    failure_message TEXT           NULL,
    notice_pending  BOOLEAN        NULL,
    notice_attempts INTEGER        NULL,
    notice_next_at  TIMESTAMPTZ(3) NULL
);
CREATE INDEX IF NOT EXISTS snodra_saga_dispatch_saga_seq ON snodra_saga_dispatch (saga_id, seq);
CREATE INDEX IF NOT EXISTS snodra_saga_dispatch_pending ON snodra_saga_dispatch (saga_id, seq) WHERE dispatched_at IS NULL AND failed_at IS NULL;
CREATE INDEX IF NOT EXISTS snodra_saga_dispatch_notice ON snodra_saga_dispatch (notice_next_at) WHERE notice_pending;
CREATE INDEX IF NOT EXISTS snodra_saga_dispatch_dispatched ON snodra_saga_dispatch (dispatched_at) WHERE dispatched_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS snodra_saga_dispatch_failed ON snodra_saga_dispatch (failed_at) WHERE failed_at IS NOT NULL;

-- One dispatch relay instance per saga at a time.
CREATE TABLE IF NOT EXISTS snodra_saga_dispatch_leases (
    saga_id     VARCHAR(255) COLLATE "C" NOT NULL PRIMARY KEY,
    owner       TEXT           NOT NULL,
    lease_until TIMESTAMPTZ(3) NOT NULL
);

-- Saga deadlines. payload is JSON text (any JSON value), kept as written.
CREATE TABLE IF NOT EXISTS snodra_deadlines (
    id             VARCHAR(255) COLLATE "C" NOT NULL PRIMARY KEY,
    saga_type      VARCHAR(255) COLLATE "C" NOT NULL,
    saga_id        VARCHAR(255) COLLATE "C" NOT NULL,
    name           VARCHAR(255) COLLATE "C" NOT NULL,
    payload        TEXT           NULL,
    payload_type   TEXT           NULL,
    due_at         TIMESTAMPTZ(3) NOT NULL,
    correlation_id TEXT           NOT NULL,
    status         VARCHAR(16)    NOT NULL,
    claimed_by     TEXT           NULL,
    claimed_until  TIMESTAMPTZ(3) NULL,
    finished_at    TIMESTAMPTZ(3) NULL
);
CREATE INDEX IF NOT EXISTS snodra_deadlines_due ON snodra_deadlines (status, due_at);
CREATE INDEX IF NOT EXISTS snodra_deadlines_saga ON snodra_deadlines (saga_id, status);
CREATE INDEX IF NOT EXISTS snodra_deadlines_finished ON snodra_deadlines (finished_at) WHERE finished_at IS NOT NULL;

-- Saga events parked after their last attempt. id = <sagaType>:<eventId>.
CREATE TABLE IF NOT EXISTS snodra_saga_failures (
    id_hash         CHAR(64) COLLATE "C" NOT NULL PRIMARY KEY,
    id              TEXT           NOT NULL,
    saga_type       VARCHAR(255) COLLATE "C" NOT NULL,
    event_id        TEXT           NOT NULL,
    event_type      TEXT           NOT NULL,
    payload         TEXT           NOT NULL,
    headers         JSONB          NOT NULL,
    error           TEXT           NOT NULL,
    attempts        INTEGER        NOT NULL,
    first_failed_at TIMESTAMPTZ(3) NOT NULL,
    last_failed_at  TIMESTAMPTZ(3) NOT NULL
);
CREATE INDEX IF NOT EXISTS snodra_saga_failures_type ON snodra_saga_failures (saga_type, last_failed_at);
CREATE INDEX IF NOT EXISTS snodra_saga_failures_last ON snodra_saga_failures (last_failed_at);

INSERT INTO snodra_schema (version) VALUES (1) ON CONFLICT (version) DO NOTHING;
