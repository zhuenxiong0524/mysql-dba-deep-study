\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS lab_redo_log CASCADE;
CREATE SCHEMA lab_redo_log;
CREATE TABLE lab_redo_log.t_commit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, payload text NOT NULL);
SELECT version();
SELECT name, setting FROM pg_settings
 WHERE name IN ('synchronous_commit','synchronous_standby_names','wal_writer_delay')
 ORDER BY name;

\timing on
SET synchronous_commit = 'on';
SELECT format('INSERT INTO lab_redo_log.t_commit(payload) VALUES (%L)', 'on-' || g)
FROM generate_series(1,100) g \gexec
SELECT current_setting('synchronous_commit') mode, pg_current_wal_insert_lsn() insert_lsn,
       pg_current_wal_flush_lsn() flush_lsn;

SET synchronous_commit = 'local';
SELECT format('INSERT INTO lab_redo_log.t_commit(payload) VALUES (%L)', 'local-' || g)
FROM generate_series(1,100) g \gexec
SELECT current_setting('synchronous_commit') mode, pg_current_wal_insert_lsn() insert_lsn,
       pg_current_wal_flush_lsn() flush_lsn;

SET synchronous_commit = 'remote_write';
SELECT format('INSERT INTO lab_redo_log.t_commit(payload) VALUES (%L)', 'remote_write-' || g)
FROM generate_series(1,100) g \gexec
SELECT current_setting('synchronous_commit') mode, pg_current_wal_insert_lsn() insert_lsn,
       pg_current_wal_flush_lsn() flush_lsn;

SET synchronous_commit = 'remote_apply';
SELECT format('INSERT INTO lab_redo_log.t_commit(payload) VALUES (%L)', 'remote_apply-' || g)
FROM generate_series(1,100) g \gexec
SELECT current_setting('synchronous_commit') mode, pg_current_wal_insert_lsn() insert_lsn,
       pg_current_wal_flush_lsn() flush_lsn;

SET synchronous_commit = 'off';
SELECT format('INSERT INTO lab_redo_log.t_commit(payload) VALUES (%L)', 'off-' || g)
FROM generate_series(1,100) g \gexec
SELECT current_setting('synchronous_commit') mode, pg_current_wal_insert_lsn() insert_lsn,
       pg_current_wal_flush_lsn() flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_insert_lsn(), pg_current_wal_flush_lsn()) unflushed_bytes;
\timing off

SELECT count(*) rows_after_all_modes FROM lab_redo_log.t_commit;
RESET synchronous_commit;
DROP SCHEMA lab_redo_log CASCADE;
