\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE EXTENSION pg_fts;
CREATE TABLE src (n int, hash text, message text);
COPY src FROM '/nvme/fp/commits.tsv';
CREATE TABLE ag (id bigserial PRIMARY KEY, n int, tree_hash text, message text);
