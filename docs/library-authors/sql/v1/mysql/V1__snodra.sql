-- snodra-messaging message store, schema version 1 (MySQL 8.0.17 or later, InnoDB, a STRICT sql_mode).
-- Shared by the Kotlin add-on (snodra-messaging-jdbc) and the Rust one (snodra-messaging-sqlx): both read and write these
-- tables the same way. Idempotent: it can run again over itself. Frozen once released: later changes are V2, V3, ...
-- Times are UTC instants at millisecond precision in DATETIME(3), stamped by the application (never NOW()).
-- utf8mb4_0900_bin (NO PAD): identifiers and positions are compared and ordered by their bytes, case, accents and trailing
-- spaces included.
-- *_hash columns hold the lowercase hex SHA-256 of a value's UTF-8 bytes: they carry the uniqueness and the lookups of values
-- with no length bound (marker ids, idempotency keys, start keys, record keys, associations); the value itself is in a
-- MEDIUMTEXT column next to it. Bounded columns are checked by the libraries before any write (see the module README).
-- Free text (errors) is cut by the libraries to 16 KiB of UTF-8, which TEXT holds.

CREATE TABLE IF NOT EXISTS snodra_schema (
    version    INT         NOT NULL PRIMARY KEY,
    applied_at DATETIME(3) NOT NULL DEFAULT (UTC_TIMESTAMP(3))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- The outbox: events appended in the service's transaction, relayed to the event store afterwards.
CREATE TABLE IF NOT EXISTS snodra_outbox (
    id          VARCHAR(255) NOT NULL PRIMARY KEY,
    type        VARCHAR(255) NOT NULL,
    event_key   MEDIUMTEXT   NULL,
    headers     JSON         NOT NULL,
    payload     JSON         NOT NULL,
    created_at  DATETIME(3)  NOT NULL,
    seq         BIGINT       NOT NULL,
    attempts    INT          NOT NULL DEFAULT 0,
    sent_at     DATETIME(3)  NULL,
    failed_at   DATETIME(3)  NULL,
    last_error  TEXT         NULL,
    owner       MEDIUMTEXT   NULL,
    lease_until DATETIME(3)  NULL,
    INDEX snodra_outbox_pending (sent_at, failed_at, created_at, seq)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Processed-event markers: one per id (processor:<name>:<eventId>, saga:<type>:<eventId>, ingress:<source>:<key>, ...).
-- A stage-1 marker also carries its processor, source, segment and position (position_num: the position as a number when
-- it is a canonical decimal one, so a reset deletes a range by value).
CREATE TABLE IF NOT EXISTS snodra_processed_events (
    id_hash      CHAR(64)     NOT NULL PRIMARY KEY,
    id           MEDIUMTEXT   NOT NULL,
    type         MEDIUMTEXT   NOT NULL,
    processed_at DATETIME(3)  NOT NULL,
    processor    VARCHAR(64)  NULL,
    source       VARCHAR(255) NULL,
    segment      VARCHAR(128) NULL,
    position     VARCHAR(128) NULL,
    position_num BIGINT       NULL,
    INDEX snodra_processed_events_range (processor, source, segment, position_num),
    INDEX snodra_processed_events_processed_at (processed_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Dead letters, sequenced per (processor, key). id = <processor>:<source>:<segment>:<position> (at most 578).
CREATE TABLE IF NOT EXISTS snodra_dead_letters (
    id              VARCHAR(578) NOT NULL PRIMARY KEY,
    processor       VARCHAR(64)  NOT NULL,
    source          VARCHAR(255) NOT NULL,
    segment         VARCHAR(128) NOT NULL,
    position        VARCHAR(128) NOT NULL,
    position_num    BIGINT       NULL,
    event_key       MEDIUMTEXT   NULL,
    event_key_hash  CHAR(64)     NULL,
    event_id        MEDIUMTEXT   NULL,
    event_type      MEDIUMTEXT   NULL,
    headers         JSON         NOT NULL,
    payload         MEDIUMTEXT   NULL,
    payload_binary  LONGBLOB     NULL,
    reason          VARCHAR(32)  NOT NULL,
    error_type      TEXT         NOT NULL,
    error_message   TEXT         NOT NULL,
    blocked_by      MEDIUMTEXT   NULL,
    attempts        INT          NOT NULL,
    parked_at       DATETIME(3)  NOT NULL,
    last_attempt_at DATETIME(3)  NOT NULL,
    expire_at       DATETIME(3)  NOT NULL,
    replay          BOOLEAN      NOT NULL DEFAULT FALSE,
    INDEX snodra_dead_letters_key (processor, event_key_hash, position_num),
    INDEX snodra_dead_letters_parked (processor, parked_at),
    INDEX snodra_dead_letters_expire (expire_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- One row per event processor: its pause, the reset operation holding its lock, its open replay ranges
-- (a JSON array of {"source","segment","from","until"} strings, in order).
CREATE TABLE IF NOT EXISTS snodra_processor_control (
    processor      VARCHAR(64) NOT NULL PRIMARY KEY,
    paused         BOOLEAN     NOT NULL DEFAULT FALSE,
    paused_at      DATETIME(3) NULL,
    paused_by      MEDIUMTEXT  NULL,
    op_id          MEDIUMTEXT  NULL,
    op_kind        MEDIUMTEXT  NULL,
    op_lease_until DATETIME(3) NULL,
    op_prepared_at DATETIME(3) NULL,
    replay         JSON        NOT NULL,
    updated_at     DATETIME(3) NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Idempotent external calls and ingress (@IdempotentHandler): one record per idempotency key (id). reply and error are JSON
-- text, kept as written.
CREATE TABLE IF NOT EXISTS snodra_external_calls (
    id_hash     CHAR(64)    NOT NULL PRIMARY KEY,
    id          MEDIUMTEXT  NOT NULL,
    status      VARCHAR(32) NOT NULL,
    reply       MEDIUMTEXT  NULL,
    error       MEDIUMTEXT  NULL,
    attempts    INT         NOT NULL,
    updated_at  DATETIME(3) NOT NULL,
    lease_until DATETIME(3) NULL,
    owner       MEDIUMTEXT  NULL,
    INDEX snodra_external_calls_updated (updated_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Saga instances. state is the saga as JSON text, kept as written. live_start_key_hash is the start key's hash
-- while the saga is live: its unique index lets one live saga hold a start key.
CREATE TABLE IF NOT EXISTS snodra_sagas (
    id                  VARCHAR(255) NOT NULL PRIMARY KEY,
    type                VARCHAR(255) NOT NULL,
    state               MEDIUMTEXT   NOT NULL,
    start_key           MEDIUMTEXT   NULL,
    start_key_hash      CHAR(64)     NULL,
    ended               BOOLEAN      NOT NULL,
    ended_at            DATETIME(3)  NULL,
    version             BIGINT       NOT NULL,
    created_at          DATETIME(3)  NOT NULL,
    updated_at          DATETIME(3)  NOT NULL,
    live_start_key_hash CHAR(64) GENERATED ALWAYS AS (CASE WHEN ended THEN NULL ELSE start_key_hash END) STORED,
    UNIQUE INDEX snodra_sagas_live_start_key (live_start_key_hash),
    INDEX snodra_sagas_type_ended (type, ended),
    INDEX snodra_sagas_ended_at (ended_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- A saga's associations key = value, in order (idx from 0): what routes events to it. assoc_hash = SHA-256 of
-- key, a zero byte, value.
CREATE TABLE IF NOT EXISTS snodra_saga_associations (
    saga_id     VARCHAR(255) NOT NULL,
    idx         INT          NOT NULL,
    assoc_key   MEDIUMTEXT   NOT NULL,
    assoc_value MEDIUMTEXT   NOT NULL,
    assoc_hash  CHAR(64)     NOT NULL,
    PRIMARY KEY (saga_id, idx),
    INDEX snodra_saga_associations_hash (assoc_hash),
    CONSTRAINT snodra_saga_associations_saga FOREIGN KEY (saga_id) REFERENCES snodra_sagas (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- The saga-side outbox: commands and events a saga recorded, sent in seq order per saga.
CREATE TABLE IF NOT EXISTS snodra_saga_dispatch (
    id              VARCHAR(255) NOT NULL PRIMARY KEY,
    saga_id         VARCHAR(255) NOT NULL,
    seq             BIGINT       NOT NULL,
    kind            VARCHAR(16)  NOT NULL,
    type            VARCHAR(255) NOT NULL,
    payload         MEDIUMTEXT   NOT NULL,
    headers         JSON         NOT NULL,
    routing_key     MEDIUMTEXT   NULL,
    created_at      DATETIME(3)  NOT NULL,
    dispatched_at   DATETIME(3)  NULL,
    attempts        INT          NOT NULL,
    next_attempt_at DATETIME(3)  NULL,
    failed_at       DATETIME(3)  NULL,
    failure_reason  VARCHAR(32)  NULL,
    failure_message TEXT         NULL,
    notice_pending  BOOLEAN      NULL,
    notice_attempts INT          NULL,
    notice_next_at  DATETIME(3)  NULL,
    INDEX snodra_saga_dispatch_saga_seq (saga_id, seq),
    INDEX snodra_saga_dispatch_pending (dispatched_at, failed_at, saga_id, seq),
    INDEX snodra_saga_dispatch_notice (notice_pending, notice_next_at),
    INDEX snodra_saga_dispatch_failed (failed_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- One dispatch relay instance per saga at a time.
CREATE TABLE IF NOT EXISTS snodra_saga_dispatch_leases (
    saga_id     VARCHAR(255) NOT NULL PRIMARY KEY,
    owner       MEDIUMTEXT   NOT NULL,
    lease_until DATETIME(3)  NOT NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Saga deadlines. payload is JSON text (any JSON value), kept as written.
CREATE TABLE IF NOT EXISTS snodra_deadlines (
    id             VARCHAR(255) NOT NULL PRIMARY KEY,
    saga_type      VARCHAR(255) NOT NULL,
    saga_id        VARCHAR(255) NOT NULL,
    name           VARCHAR(255) NOT NULL,
    payload        MEDIUMTEXT   NULL,
    payload_type   MEDIUMTEXT   NULL,
    due_at         DATETIME(3)  NOT NULL,
    correlation_id MEDIUMTEXT   NOT NULL,
    status         VARCHAR(16)  NOT NULL,
    claimed_by     MEDIUMTEXT   NULL,
    claimed_until  DATETIME(3)  NULL,
    finished_at    DATETIME(3)  NULL,
    INDEX snodra_deadlines_due (status, due_at),
    INDEX snodra_deadlines_saga (saga_id, status),
    INDEX snodra_deadlines_finished (finished_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

-- Saga events parked after their last attempt. id = <sagaType>:<eventId>.
CREATE TABLE IF NOT EXISTS snodra_saga_failures (
    id_hash         CHAR(64)     NOT NULL PRIMARY KEY,
    id              MEDIUMTEXT   NOT NULL,
    saga_type       VARCHAR(255) NOT NULL,
    event_id        MEDIUMTEXT   NOT NULL,
    event_type      MEDIUMTEXT   NOT NULL,
    payload         MEDIUMTEXT   NOT NULL,
    headers         JSON         NOT NULL,
    error           TEXT         NOT NULL,
    attempts        INT          NOT NULL,
    first_failed_at DATETIME(3)  NOT NULL,
    last_failed_at  DATETIME(3)  NOT NULL,
    INDEX snodra_saga_failures_type (saga_type, last_failed_at),
    INDEX snodra_saga_failures_last (last_failed_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_bin;

INSERT INTO snodra_schema (version) VALUES (1) ON DUPLICATE KEY UPDATE version = version;
