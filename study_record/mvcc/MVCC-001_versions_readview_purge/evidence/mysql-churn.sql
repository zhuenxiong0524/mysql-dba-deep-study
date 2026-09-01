USE mysql_mvcc001;
UPDATE mvcc_lab SET version_no=1, payload='v1' WHERE id=1;
CALL churn_versions(200);
SELECT * FROM mvcc_lab;
