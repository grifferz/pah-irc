-- Convert schema 'sql/PAH-Schema-0.0011-SQLite.sql' to 'sql/PAH-Schema-0.0012-SQLite.sql':;

BEGIN;

CREATE TABLE "waiters" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user" integer NOT NULL,
  "game" integer NOT NULL,
  "wait_since" integer NOT NULL DEFAULT 0,
  FOREIGN KEY ("game") REFERENCES "games"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY ("user") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "waiters_idx_game" ON "waiters" ("game");

CREATE INDEX "waiters_idx_user" ON "waiters" ("user");

CREATE UNIQUE INDEX "waiter_user_game_idx" ON "waiters" ("user", "game");


COMMIT;

