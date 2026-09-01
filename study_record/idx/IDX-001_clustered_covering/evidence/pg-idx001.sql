-- IDX-001 / PostgreSQL 18.4
-- Run after creating and connecting to database pg_idx001.

CREATE TABLE idx_lab (
  id BIGINT PRIMARY KEY,
  tenant_id INT NOT NULL,
  status SMALLINT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  payload VARCHAR(200) NOT NULL
);

-- Same descending primary-key insertion order as MySQL.
INSERT INTO idx_lab(id, tenant_id, status, created_at, payload)
SELECT 30001 - n,
       MOD(30001 - n, 100),
       MOD(30001 - n, 5),
       TIMESTAMP '2026-01-01 00:00:00' + (30001 - n) * INTERVAL '1 second',
       'payload-' || LPAD((30001 - n)::text, 6, '0') || '-' || REPEAT('x', 80)
FROM generate_series(1,30000) AS g(n);

CREATE INDEX idx_tenant ON idx_lab(tenant_id);
-- PG secondary indexes do not implicitly carry the primary key. INCLUDE id
-- explicitly to make the same projection coverable.
CREATE INDEX idx_cover ON idx_lab(tenant_id, status) INCLUDE(id, created_at);
VACUUM (ANALYZE) idx_lab;

\echo 'A. environment and row count'
SELECT version();
SELECT current_setting('block_size') AS block_size,
       COUNT(*) AS rows_count, MIN(id) AS min_id, MAX(id) AS max_id
FROM idx_lab;

\echo 'B. PostgreSQL is heap + independent indexes'
SELECT c.relname, c.relkind, c.relfilenode, pg_relation_size(c.oid) AS bytes
FROM pg_class c
WHERE c.relname IN ('idx_lab','idx_lab_pkey','idx_tenant','idx_cover')
ORDER BY c.relkind, c.relname;
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname='public' AND tablename='idx_lab' ORDER BY indexname;

\echo 'C. heap physical order follows descending insertion, not primary key'
SELECT ctid, id, tenant_id FROM idx_lab LIMIT 5;

\echo 'D. primary-key B-tree lookup still fetches heap tuple'
SET enable_seqscan=off;
SET enable_bitmapscan=off;
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS OFF)
SELECT payload FROM idx_lab WHERE id=42;

\echo 'E1. secondary index query needs payload: Index Scan then heap fetch'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS OFF)
SELECT payload FROM idx_lab WHERE tenant_id=42;

\echo 'E2. same predicate/projection: INCLUDE enables Index Only Scan'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS OFF)
SELECT id, tenant_id, status, created_at
FROM idx_lab WHERE tenant_id=42 AND status=2;

\echo 'F. visibility map is part of PG index-only semantics'
-- pg_visibility extension is not installed in this source build. The core
-- catalog still exposes VACUUM's all-visible page count.
SELECT relpages, relallvisible,
       relallvisible = relpages AS all_heap_pages_visible
FROM pg_class WHERE oid='idx_lab'::regclass;
