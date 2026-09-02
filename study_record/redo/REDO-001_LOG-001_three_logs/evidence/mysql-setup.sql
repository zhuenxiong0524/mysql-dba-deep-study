DROP DATABASE IF EXISTS mysql_lab_redo_log;
CREATE DATABASE mysql_lab_redo_log;
USE mysql_lab_redo_log;

CREATE TABLE t_log_lab (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(80) NOT NULL,
  amount INT NOT NULL
) ENGINE=InnoDB;
