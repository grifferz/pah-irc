-- Convert schema 'sql/PAH-Schema-0.0004-SQLite.sql' to 'sql/PAH-Schema-0.0005-SQLite.sql':;

BEGIN;

CREATE TEMPORARY TABLE "users_games_temp_alter" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user" integer NOT NULL,
  "game" integer NOT NULL,
  "wins" integer NOT NULL DEFAULT 0,
  "hands" integer NOT NULL DEFAULT 0,
  "tsarcount" integer NOT NULL DEFAULT 0,
  "is_tsar" integer NOT NULL DEFAULT 0,
  "activity_time" integer NOT NULL DEFAULT 0,
  "active" integer NOT NULL DEFAULT 1,
  FOREIGN KEY ("game") REFERENCES "games"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY ("user") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

INSERT INTO "users_games_temp_alter"( "id", "user", "game", "wins", "hands", "tsarcount", "is_tsar", "active") SELECT "id", "user", "game", "wins", "hands", "tsarcount", "is_tsar", "active" FROM "users_games";

DROP TABLE "users_games";

CREATE TABLE "users_games" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user" integer NOT NULL,
  "game" integer NOT NULL,
  "wins" integer NOT NULL DEFAULT 0,
  "hands" integer NOT NULL DEFAULT 0,
  "tsarcount" integer NOT NULL DEFAULT 0,
  "is_tsar" integer NOT NULL DEFAULT 0,
  "activity_time" integer NOT NULL DEFAULT 0,
  "active" integer NOT NULL DEFAULT 1,
  FOREIGN KEY ("game") REFERENCES "games"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY ("user") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "users_games_idx_game03" ON "users_games" ("game");

CREATE INDEX "users_games_idx_user03" ON "users_games" ("user");

CREATE UNIQUE INDEX "users_games_user_game_idx03" ON "users_games" ("user", "game");

INSERT INTO "users_games" SELECT "id", "user", "game", "wins", "hands", "tsarcount", "is_tsar", "activity_time", "active" FROM "users_games_temp_alter";

DROP TABLE "users_games_temp_alter";


COMMIT;

