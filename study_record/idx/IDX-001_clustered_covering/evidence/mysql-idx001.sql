-- IDX-001 / MySQL 8.4.10
-- Same logical dataset and predicates as pg-idx001.sql.

DROP DATABASE IF EXISTS mysql_idx001;
CREATE DATABASE mysql_idx001;
USE mysql_idx001;

CREATE TABLE idx_lab (
  id BIGINT NOT NULL,
  tenant_id INT NOT NULL,
  status TINYINT NOT NULL,
  created_at DATETIME NOT NULL,
  payload VARCHAR(200) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_tenant (tenant_id),
  KEY idx_cover (tenant_id, status, created_at)
) ENGINE=InnoDB;

-- Insert in descending primary-key order. InnoDB still stores the leaf data
-- in PRIMARY-key order; PostgreSQL keeps this insertion order in the heap.
INSERT INTO idx_lab(id, tenant_id, status, created_at, payload)
SELECT 30001 - n,
       MOD(30001 - n, 100),
       MOD(30001 - n, 5),
       TIMESTAMP('2026-01-01 00:00:00') + INTERVAL (30001 - n) SECOND,
       CONCAT('payload-', LPAD(30001 - n, 6, '0'), '-', REPEAT('x', 80))
FROM (
  SELECT 1 + u.n + 10*t.n + 100*h.n + 1000*th.n + 10000*tt.n AS n
  FROM
    (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) u
  CROSS JOIN
    (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t
  CROSS JOIN
    (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) h
  CROSS JOIN
    (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) th
  CROSS JOIN
    (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) tt
) seq
WHERE n <= 30000;

ANALYZE TABLE idx_lab;

SELECT 'A. environment and row count' AS section;
SELECT VERSION() AS version, @@default_storage_engine AS default_engine,
       @@innodb_page_size AS innodb_page_size;
SELECT COUNT(*) AS rows_count, MIN(id) AS min_id, MAX(id) AS max_id FROM idx_lab;

SELECT 'B. user-visible index definition' AS section;
SHOW INDEX FROM idx_lab;

SELECT 'C. internal InnoDB indexes: secondary indexes include PRIMARY key id' AS section;
SELECT i.NAME, i.TYPE, i.N_FIELDS, i.PAGE_NO, i.SPACE
FROM information_schema.INNODB_INDEXES i
JOIN information_schema.INNODB_TABLES t ON t.TABLE_ID=i.TABLE_ID
WHERE t.NAME='mysql_idx001/idx_lab'
ORDER BY i.INDEX_ID;

SELECT 'D. clustered PRIMARY scan: insertion was descending, index output is ascending' AS section;
EXPLAIN FORMAT=TREE SELECT id, tenant_id FROM idx_lab FORCE INDEX(PRIMARY)
ORDER BY id LIMIT 5;
SELECT id, tenant_id FROM idx_lab FORCE INDEX(PRIMARY) ORDER BY id LIMIT 5;

SELECT 'E1. secondary index query needs payload: not covering, clustered lookup required' AS section;
EXPLAIN SELECT payload FROM idx_lab FORCE INDEX(idx_tenant) WHERE tenant_id=42;
EXPLAIN ANALYZE SELECT payload FROM idx_lab FORCE INDEX(idx_tenant) WHERE tenant_id=42;

SELECT 'E2. same predicate, selected columns are in idx_cover plus implicit PK: covering' AS section;
EXPLAIN SELECT id, tenant_id, status, created_at
FROM idx_lab FORCE INDEX(idx_cover) WHERE tenant_id=42 AND status=2;
EXPLAIN ANALYZE SELECT id, tenant_id, status, created_at
FROM idx_lab FORCE INDEX(idx_cover) WHERE tenant_id=42 AND status=2;

SELECT 'F. no explicit PK: InnoDB creates GEN_CLUST_INDEX' AS section;
CREATE TABLE no_pk_lab (
  a INT NOT NULL,
  b VARCHAR(40) NOT NULL,
  KEY idx_a(a)
) ENGINE=InnoDB;
INSERT INTO no_pk_lab VALUES (2,'two'),(1,'one'),(3,'three');
SELECT i.NAME, i.TYPE, i.N_FIELDS, i.PAGE_NO
FROM information_schema.INNODB_INDEXES i
JOIN information_schema.INNODB_TABLES t ON t.TABLE_ID=i.TABLE_ID
WHERE t.NAME='mysql_idx001/no_pk_lab'
ORDER BY i.INDEX_ID;

SELECT 'G. table/index size after ANALYZE' AS section;
SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='mysql_idx001' ORDER BY TABLE_NAME;
