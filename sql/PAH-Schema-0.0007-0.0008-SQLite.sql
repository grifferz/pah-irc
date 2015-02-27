-- Convert schema 'sql/PAH-Schema-0.0007-SQLite.sql' to 'sql/PAH-Schema-0.0008-SQLite.sql':;

BEGIN;

ALTER TABLE "users" ADD COLUMN "disp_nick" varchar(50);

CREATE UNIQUE INDEX "users_disp_nick_idx02" ON "users" ("disp_nick");


COMMIT;

