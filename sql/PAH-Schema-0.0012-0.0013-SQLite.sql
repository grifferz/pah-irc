-- Convert schema 'sql/PAH-Schema-0.0012-SQLite.sql' to 'sql/PAH-Schema-0.0013-SQLite.sql':;

BEGIN;

CREATE TABLE "settings" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user" integer NOT NULL,
  "pronoun" varchar(5) DEFAULT NULL,
  "chatpoke" integer NOT NULL DEFAULT 1,
  FOREIGN KEY ("user") REFERENCES "users"("id") ON DELETE CASCADE
);

CREATE INDEX "settings_idx_user" ON "settings" ("user");

CREATE UNIQUE INDEX "settings_user_idx" ON "settings" ("user");

-- Any user that has a custom pronoun will get it migrated to here.
INSERT INTO settings (user, pronoun) SELECT id, pronoun FROM users WHERE pronoun IS NOT NULL;

COMMIT;

