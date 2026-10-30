-- A tenant-scoped memory table under row-level security, isolated on two axes:
-- customer and project. A session bound to one (customer, project) can see and write
-- only its own rows, so a shared project label never leaks across customers and a
-- shared customer never leaks across projects. Separate from memory.record so the
-- recovery scenarios, which run as the bypassing superuser, are unaffected.
CREATE TABLE memory.tenant_record (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id text NOT NULL,
  project_id  text NOT NULL,
  content     text NOT NULL
);
ALTER TABLE memory.tenant_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory.tenant_record FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON memory.tenant_record
  USING      (customer_id = current_setting('app.customer_id', true)
              AND project_id = current_setting('app.project_id', true))
  WITH CHECK (customer_id = current_setting('app.customer_id', true)
              AND project_id = current_setting('app.project_id', true));
GRANT SELECT, INSERT ON memory.tenant_record TO core_app;
