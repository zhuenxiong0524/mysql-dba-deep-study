DROP DATABASE IF EXISTS mysql_iso001;
CREATE DATABASE mysql_iso001;
USE mysql_iso001;

CREATE TABLE range_lab (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(40) NOT NULL
) ENGINE=InnoDB;
INSERT INTO range_lab VALUES (10,'ten'),(20,'twenty'),(30,'thirty');

CREATE TABLE account_lab (
  id INT NOT NULL PRIMARY KEY,
  balance INT NOT NULL
) ENGINE=InnoDB;
INSERT INTO account_lab VALUES (1,100),(2,100);

CREATE TABLE doctor_lab (
  id INT NOT NULL PRIMARY KEY,
  on_call TINYINT NOT NULL
) ENGINE=InnoDB;
INSERT INTO doctor_lab VALUES (1,1),(2,1);

SELECT VERSION() AS version, @@transaction_isolation AS default_isolation,
       @@innodb_deadlock_detect AS deadlock_detect,
       @@innodb_lock_wait_timeout AS lock_wait_timeout;
