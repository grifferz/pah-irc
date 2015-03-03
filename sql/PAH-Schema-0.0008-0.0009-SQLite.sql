-- Convert schema 'sql/PAH-Schema-0.0008-SQLite.sql' to 'sql/PAH-Schema-0.0009-SQLite.sql':;

BEGIN;

ALTER TABLE "users_games_hands" ADD COLUMN "pos" integer DEFAULT NULL;

CREATE UNIQUE INDEX "users_games_hands_user_game00" ON "users_games_hands" ("user_game", "pos");


COMMIT;

