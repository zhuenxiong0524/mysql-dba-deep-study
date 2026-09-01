-- psql \gexec executes every generated UPDATE as a separate autocommit
-- transaction, matching MySQL churn_versions(200)'s separate commits.
UPDATE mvcc_lab SET version_no=1, payload='v1' WHERE id=1;
SELECT format(
  'UPDATE mvcc_lab SET version_no=version_no+1, payload=%L || (version_no+1)::text WHERE id=1;',
  'v')
FROM generate_series(1,200)
\gexec
SELECT xmin::text, xmax::text, ctid, * FROM mvcc_lab;
