-- Convert schema 'sql/PAH-Schema-0.0010-SQLite.sql' to 'sql/PAH-Schema-0.0011-SQLite.sql':;

BEGIN;

CREATE TEMPORARY TABLE "users_games_hands_temp_alter" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user_game" integer NOT NULL,
  "wcardidx" integer,
  "pos" integer DEFAULT NULL,
  FOREIGN KEY ("user_game") REFERENCES "users_games"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

INSERT INTO "users_games_hands_temp_alter"( "id", "user_game", "wcardidx", "pos") SELECT "id", "user_game", "wcardidx", "pos" FROM "users_games_hands";

DROP TABLE "users_games_hands";

CREATE TABLE "users_games_hands" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "user_game" integer NOT NULL,
  "wcardidx" integer,
  "pos" integer DEFAULT NULL,
  FOREIGN KEY ("user_game") REFERENCES "users_games"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "users_games_hands_idx_user_00" ON "users_games_hands" ("user_game");

CREATE UNIQUE INDEX "users_games_hands_user_game00" ON "users_games_hands" ("user_game", "pos");

CREATE UNIQUE INDEX "users_games_hands_user_game01" ON "users_games_hands" ("user_game", "wcardidx");

INSERT INTO "users_games_hands" SELECT "id", "user_game", "wcardidx", "pos" FROM "users_games_hands_temp_alter";

DROP TABLE "users_games_hands_temp_alter";


COMMIT;

