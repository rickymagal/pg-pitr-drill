-- A project-scoped memory table under row-level security, demonstrating that a
-- session bound to one project can see and write only its own rows. Separate from
-- memory.record so the recovery scenarios, which run as the bypassing superuser, are
-- unaffected.
CREATE TABLE memory.tenant_record (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id text NOT NULL,
  content    text NOT NULL
);
ALTER TABLE memory.tenant_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory.tenant_record FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON memory.tenant_record
  USING      (project_id = current_setting('app.project_id', true))
  WITH CHECK (project_id = current_setting('app.project_id', true));
GRANT SELECT, INSERT ON memory.tenant_record TO core_app;
