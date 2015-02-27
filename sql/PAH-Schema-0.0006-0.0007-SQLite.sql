-- Convert schema 'sql/PAH-Schema-0.0006-SQLite.sql' to 'sql/PAH-Schema-0.0007-SQLite.sql':;

BEGIN;

ALTER TABLE "games" ADD COLUMN "round_time" integer NOT NULL DEFAULT 0;


COMMIT;

