-- The six logical data domains of a secure AI platform, with least-privilege,
-- default-deny roles. Applied once at cluster initialization. The grants enforce
-- three boundaries the platform depends on: the application cannot promote itself
-- into policy/authority, evidence is append-only, and the operator has no direct
-- database path.

-- Six logical domains, one schema each.
CREATE SCHEMA workflow;     -- authoritative workflow and task state
CREATE SCHEMA memory;       -- persistent AI memory
CREATE SCHEMA source_docs;  -- source documents and knowledge records
CREATE SCHEMA audit;        -- audit, evidence, and provenance history
CREATE SCHEMA runtime;      -- runtime context and caches
CREATE SCHEMA authority;    -- policy, permission, approval, Human Authority

-- Memory records keep provenance and an explicit lifecycle state, so a record
-- can be quarantined or superseded without being destroyed.
CREATE TYPE memory.record_state AS ENUM
  ('unverified','verified','rejected','quarantined','repaired','superseded','current');

CREATE TABLE memory.record (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content         text NOT NULL,
  source_id       text,                        -- original source, never replaced by a summary
  provenance      text,                        -- where the record came from
  authority_scope text,                        -- permission/scope carried from the source
  state           memory.record_state NOT NULL DEFAULT 'unverified',
  superseded_by   bigint REFERENCES memory.record(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  verified_at     timestamptz
);

CREATE TABLE source_docs.document (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  uri        text NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workflow.task (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title      text NOT NULL,
  status     text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Authority labels are assigned by independently controlled systems, never by
-- the text of a memory record.
CREATE TABLE authority.policy (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       text NOT NULL,
  decided_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Evidence is append-only: writable and readable, never updated or deleted.
CREATE TABLE audit.event (
  id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at     timestamptz NOT NULL DEFAULT now(),
  actor  text NOT NULL,
  action text NOT NULL,
  detail text
);

CREATE TABLE runtime.cache (
  key        text PRIMARY KEY,
  value      text,
  expires_at timestamptz
);

-- Default-deny: PUBLIC gets nothing on any domain.
REVOKE ALL ON SCHEMA workflow, memory, source_docs, audit, runtime, authority FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA workflow, memory, source_docs, audit, runtime, authority FROM PUBLIC;

-- The Core's narrow application role and the untrusted Operator role.
CREATE ROLE core_app NOLOGIN;
CREATE ROLE ai_operator NOLOGIN;

-- The Core uses and writes the working domains, reads source documents and
-- authority, and appends (never rewrites) evidence. It cannot write authority.
GRANT USAGE ON SCHEMA workflow, memory, source_docs, runtime, audit, authority TO core_app;
GRANT SELECT, INSERT, UPDATE ON memory.record, workflow.task, runtime.cache TO core_app;
GRANT SELECT, INSERT ON source_docs.document TO core_app;
GRANT SELECT, INSERT ON audit.event TO core_app;
GRANT SELECT ON authority.policy TO core_app;

-- ai_operator receives no grants: it reaches data only through the Core.
