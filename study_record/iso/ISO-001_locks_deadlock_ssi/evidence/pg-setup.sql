CREATE TABLE range_lab (
  id INT PRIMARY KEY,
  note VARCHAR(40) NOT NULL
);
INSERT INTO range_lab VALUES (10,'ten'),(20,'twenty'),(30,'thirty');

CREATE TABLE account_lab (
  id INT PRIMARY KEY,
  balance INT NOT NULL
);
INSERT INTO account_lab VALUES (1,100),(2,100);

CREATE TABLE doctor_lab (
  id INT PRIMARY KEY,
  on_call SMALLINT NOT NULL CHECK (on_call IN (0,1))
);
INSERT INTO doctor_lab VALUES (1,1),(2,1);

SELECT version();
SHOW default_transaction_isolation;
SHOW deadlock_timeout;
