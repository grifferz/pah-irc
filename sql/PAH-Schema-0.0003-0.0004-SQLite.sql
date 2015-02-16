-- Convert schema 'sql/PAH-Schema-0.0003-SQLite.sql' to 'sql/PAH-Schema-0.0004-SQLite.sql':;

BEGIN;

CREATE TEMPORARY TABLE "games_temp_alter" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "channel" integer NOT NULL,
  "create_time" integer NOT NULL,
  "activity_time" integer NOT NULL,
  "status" integer NOT NULL,
  "deck" varchar NOT NULL DEFAULT 'cah_uk',
  "bcardidx" integer DEFAULT NULL,
  FOREIGN KEY ("channel") REFERENCES "channels"("id") ON DELETE CASCADE,
  FOREIGN KEY ("id") REFERENCES "users_games"("game")
);

INSERT INTO "games_temp_alter"( "id", "channel", "create_time", "activity_time", "status", "deck", "bcardidx") SELECT "id", "channel", "create_time", "activity_time", "status", "deck", "bcardidx" FROM "games";

DROP TABLE "games";

CREATE TABLE "games" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "channel" integer NOT NULL,
  "create_time" integer NOT NULL,
  "activity_time" integer NOT NULL,
  "status" integer NOT NULL,
  "deck" varchar NOT NULL DEFAULT 'cah_uk',
  "bcardidx" integer DEFAULT NULL,
  FOREIGN KEY ("channel") REFERENCES "channels"("id") ON DELETE CASCADE,
  FOREIGN KEY ("id") REFERENCES "users_games"("game")
);

CREATE INDEX "games_idx_channel03" ON "games" ("channel");

CREATE INDEX "games_status_idx03" ON "games" ("status");

CREATE UNIQUE INDEX "games_channel_idx03" ON "games" ("channel");

INSERT INTO "games" SELECT "id", "channel", "create_time", "activity_time", "status", "deck", "bcardidx" FROM "games_temp_alter";

DROP TABLE "games_temp_alter";


COMMIT;

