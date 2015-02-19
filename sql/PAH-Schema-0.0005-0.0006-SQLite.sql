-- Convert schema 'sql/PAH-Schema-0.0005-SQLite.sql' to 'sql/PAH-Schema-0.0006-SQLite.sql':;

BEGIN;

ALTER TABLE "users" ADD COLUMN "pronoun" varchar(5) DEFAULT NULL;


COMMIT;

