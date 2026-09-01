CREATE TABLE mvcc_lab (
  id INT PRIMARY KEY,
  version_no INT NOT NULL,
  payload VARCHAR(100) NOT NULL
);
INSERT INTO mvcc_lab VALUES (1, 0, 'v0');
SELECT version();
SHOW default_transaction_isolation;
SELECT xmin::text, xmax::text, ctid, * FROM mvcc_lab;
