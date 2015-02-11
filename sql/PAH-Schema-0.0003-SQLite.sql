-- 
-- Created by SQL::Translator::Producer::SQLite
-- Created on Wed Feb 11 08:17:50 2015
-- 

BEGIN TRANSACTION;

--
-- Table: channels
--
DROP TABLE channels;

CREATE TABLE channels (
  id INTEGER PRIMARY KEY NOT NULL,
  name varchar(50) NOT NULL,
  disp_name varchar(50) NOT NULL,
  welcome integer(1) NOT NULL DEFAULT 0
);

CREATE INDEX channels_welcome_idx ON channels (welcome);

CREATE UNIQUE INDEX channels_disp_name_idx ON channels (disp_name);

CREATE UNIQUE INDEX channels_name_idx ON channels (name);

--
-- Table: users
--
DROP TABLE users;

CREATE TABLE users (
  id INTEGER PRIMARY KEY NOT NULL,
  nick varchar(50) NOT NULL
);

CREATE UNIQUE INDEX users_nick_idx ON users (nick);

--
-- Table: games
--
DROP TABLE games;

CREATE TABLE games (
  id INTEGER PRIMARY KEY NOT NULL,
  channel integer NOT NULL,
  create_time integer NOT NULL,
  activity_time integer NOT NULL,
  status integer NOT NULL,
  FOREIGN KEY (channel) REFERENCES channels(id) ON DELETE CASCADE
);

CREATE INDEX games_idx_channel ON games (channel);

CREATE INDEX games_status_idx ON games (status);

CREATE UNIQUE INDEX games_channel_idx ON games (channel);

--
-- Table: users_games
--
DROP TABLE users_games;

CREATE TABLE users_games (
  id INTEGER PRIMARY KEY NOT NULL,
  user integer NOT NULL,
  game integer NOT NULL,
  wins integer NOT NULL DEFAULT 0,
  hands integer NOT NULL DEFAULT 0,
  tsarcount integer NOT NULL DEFAULT 0,
  is_tsar integer NOT NULL DEFAULT 0,
  wait_since integer NOT NULL DEFAULT 0,
  active integer NOT NULL DEFAULT 1,
  FOREIGN KEY (game) REFERENCES games(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (user) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX users_games_idx_game ON users_games (game);

CREATE INDEX users_games_idx_user ON users_games (user);

CREATE UNIQUE INDEX users_games_user_game_idx ON users_games (user, game);

COMMIT;
