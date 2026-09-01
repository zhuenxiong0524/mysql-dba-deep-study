DROP DATABASE IF EXISTS mysql_mvcc001;
CREATE DATABASE mysql_mvcc001;
USE mysql_mvcc001;

CREATE TABLE mvcc_lab (
  id INT NOT NULL PRIMARY KEY,
  version_no INT NOT NULL,
  payload VARCHAR(100) NOT NULL
) ENGINE=InnoDB;
INSERT INTO mvcc_lab VALUES (1, 0, 'v0');

DELIMITER //
CREATE PROCEDURE churn_versions(IN loops INT)
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= loops DO
    UPDATE mvcc_lab
       SET version_no=version_no+1,
           payload=CONCAT('v', version_no)
     WHERE id=1;
    COMMIT;
    SET i=i+1;
  END WHILE;
END//
DELIMITER ;

SELECT VERSION() AS version, @@transaction_isolation AS default_isolation,
       @@innodb_purge_threads AS purge_threads;
SELECT * FROM mvcc_lab;
