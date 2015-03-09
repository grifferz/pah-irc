-- Convert schema 'sql/PAH-Schema-0.0009-SQLite.sql' to 'sql/PAH-Schema-0.0011-SQLite.sql':;

BEGIN;

CREATE TEMPORARY TABLE "games_temp_alter" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "channel" integer NOT NULL,
  "create_time" integer NOT NULL,
  "activity_time" integer NOT NULL,
  "round_time" integer NOT NULL DEFAULT 0,
  "status" integer NOT NULL,
  "packs" varchar NOT NULL DEFAULT 'cah_uk',
  "bcardidx" integer DEFAULT NULL,
  FOREIGN KEY ("channel") REFERENCES "channels"("id") ON DELETE CASCADE,
  FOREIGN KEY ("id") REFERENCES "users_games"("game")
);

INSERT INTO "games_temp_alter"( "id", "channel", "create_time", "activity_time", "round_time", "status", "bcardidx") SELECT "id", "channel", "create_time", "activity_time", "round_time", "status", "bcardidx" FROM "games";

DROP TABLE "games";

CREATE TABLE "games" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "channel" integer NOT NULL,
  "create_time" integer NOT NULL,
  "activity_time" integer NOT NULL,
  "round_time" integer NOT NULL DEFAULT 0,
  "status" integer NOT NULL,
  "packs" varchar NOT NULL DEFAULT 'cah_uk',
  "bcardidx" integer DEFAULT NULL,
  FOREIGN KEY ("channel") REFERENCES "channels"("id") ON DELETE CASCADE,
  FOREIGN KEY ("id") REFERENCES "users_games"("game")
);

CREATE INDEX "games_idx_channel03" ON "games" ("channel");

CREATE INDEX "games_status_idx03" ON "games" ("status");

CREATE UNIQUE INDEX "games_channel_idx03" ON "games" ("channel");

INSERT INTO "games" SELECT "id", "channel", "create_time", "activity_time", "round_time", "status", "packs", "bcardidx" FROM "games_temp_alter";

DROP TABLE "games_temp_alter";

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

