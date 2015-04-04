# Change log

## v0.6
### 2015-04-04
* Cards Against Humanity Holiday 2013 Expansion added (Douglas Gardner): [#127](https://github.com/grifferz/pah-irc/pull/127).
* Cards Against Humanity 3rd Expansion, PAX East and PAX Prime added (Douglas Gardner): [#123](https://github.com/grifferz/pah-irc/pull/123).
* Added Lugradio-themed card pack from Bruno Bord, though it will need work before it's usable: [#120](https://github.com/grifferz/pah-irc/issues/120).
* Bot now checks it's in the correct channels whenever it has identified to its nickname and again periodically. This solves the problem where it tries to join channels before it's identified to its nick, fails for those that require a registered nickname, and never tries again: [#122](https://github.com/grifferz/pah-irc/issues/122).
* Bot is now able to kick someone off that is using its nick, and take its nick back: [#94](https://github.com/grifferz/pah-irc/issues/94).
* Added `quit` command as an alias for `resign`: [#119](https://github.com/grifferz/pah-irc/issues/119).
* Batched notification of plays made now happens after a maximum of 30 minutes. Previously this was `turnclock` divided by 60 (24 minutes per day of `turnclock`), or 72 minutes for a game with a `turnclock` of 3 days, which was felt to be too long: [#117](https://github.com/grifferz/pah-irc/issues/117).
* Bot now asks ChanServ for voice whenever it joins a channel, as having the bot voiced is required to avoid flood-limiting: [#116](https://github.com/grifferz/pah-irc/issues/116).
* Players who try to join the game while it's waiting for the Tsar to pick the winner are now automatically added at the next round, instead of being told to try again later: [#39](https://github.com/grifferz/pah-irc/issues/39).
* Fixed bug where someone resigning after the round has already been completed could potentially extend the round time out by another full `turnclock`: [#126](https://github.com/grifferz/pah-irc/issues/126).
* Fixed cosmetic bug where nothing would appear to happen when a non-player tried to pick the winner: [#121](https://github.com/grifferz/pah-irc/issues/121).
* Fixed minor bug in the `status` command where it said you were already playing even if you weren't: [#112](https://github.com/grifferz/pah-irc/issues/112).
* Fixed some more places where a lowercased version of a player's nickname would be used: [#101](https://github.com/grifferz/pah-irc/issues/101).

## v0.5
### 2015-03-22
* Implemented support for multiple card packs (currently a bot-wide setting): [#75](https://github.com/grifferz/pah-irc/issues/75).
* Added `plays` public and private commands to repeat the list of played cards for the completed hand: [#10](https://github.com/grifferz/pah-irc/issues/10).
* Fixed bug where changing your play would cause the wrong number of plays to be reported: [#89](https://github.com/grifferz/pah-irc/issues/89).
* Fixed bug where a full `turnclock` would be allowed to pass between each forced resignation: [#84](https://github.com/grifferz/pah-irc/issues/84).
* Fixed bug where some long Black Card content would have a spurious extra newline at the end: [#90](https://github.com/grifferz/pah-irc/issues/90).
* Fixed many instances of incorrect downcasing of nicknames: [#1](https://github.com/grifferz/pah-irc/issues/1).

## v0.4
### 2015-03-03
* Now keeps cards in hands in the same order and shows the position of new cards as they are dealt: [#4](https://github.com/grifferz/pah-irc/issues/4).
* Token bucket rate limiter used for all messages: [#16](https://github.com/grifferz/pah-irc/issues/16).
* Add a private `status` command: [#61](https://github.com/grifferz/pah-irc/issues/61).
* Private `status` output includes any play the user has made: [#88](https://github.com/grifferz/pah-irc/issues/88).
* Nag players to make their play if we see them talk: [#67](https://github.com/grifferz/pah-irc/issues/67).
* Pad play number to two spaces when there's 10 or more of them: [#51](https://github.com/grifferz/pah-irc/issues/51).
* Warning about turn length is now based on `turnclock`: [#76](https://github.com/grifferz/pah-irc/issues/76).
* Prioritise channel messages: [#83](https://github.com/grifferz/pah-irc/issues/83).
* Scores removed from `status` command and added to new `stats` command: [#78](https://github.com/grifferz/pah-irc/issues/78).
* `status` command now shows when round started and how long before idle punishment: [#66](https://github.com/grifferz/pah-irc/issues/66).
* Channel is now informed about the winning play before players' hands are topped up, avoiding long pause: [#83](https://github.com/grifferz/pah-irc/issues/83).
* Players are now also informed of the winner and their play in private message: [#80](https://github.com/grifferz/pah-irc/issues/80).
* Mixed case nicknames are now preserved: [#1](https://github.com/grifferz/pah-irc/issues/1).
* Fixed bug where Card Tsar could be forcibly resigned even while waiting for other players: [#64](https://github.com/grifferz/pah-irc/issues/64).
* Cards Against Humanity 2nd expansion added (not actually in use yet though) (Douglas Gardner): [#49](https://github.com/grifferz/pah-irc/pull/73).

## v0.3
### 2015-02-20
* Now persists plays across restarts of the bot process: [#62](https://github.com/grifferz/pah-irc/issues/62).
* Implemented personal possessive pronouns so that people don't have to make do with "their": [#13](https://github.com/grifferz/pah-irc/issues/13).
* Implemented a greetings feature where new users joining the channel are introduced to the game: [#21](https://github.com/grifferz/pah-irc/issues/21).
* Several channel messages after a winning play is selected are now compressed together onto one line for brevity. [#52](https://github.com/grifferz/pah-irc/issues/52).
* Implemented batching of play notifications so that large numbers of plays don't flood the channel: [#32](https://github.com/grifferz/pah-irc/issues/32).
* `status` output now shows if you are in the game: [#26](https://github.com/grifferz/pah-irc/issues/26).
* "Top 3 scorers" `status` line now handles ties: [#30](https://github.com/grifferz/pah-irc/issues/30).
* No longer show players with a zero score in the "top 3 scorers" `status` line: [#55](https://github.com/grifferz/pah-irc/issues/55).
* Now reports the name of the channel which a private message relates to, if the user is in multiple active games: [#57](https://github.com/grifferz/pah-irc/issues/57).
* Fixed show-stopper bug where an incorrect database column comparison could prevent players from joining any game after the first: [#58](https://github.com/grifferz/pah-irc/issues/58).
* Fixed bug where "top 3 scorers" `status` line was showing players from other channels' games: [#54](https://github.com/grifferz/pah-irc/issues/54).
* Fixed bug [#40](https://github.com/grifferz/pah-irc/issues/40) where a player merely joining the game would extend the game's timer.
* Fixed bug [#44](https://github.com/grifferz/pah-irc/issues/44) where resignation of Tsar caused plays from the previous round to be included in the next round.
* Typo fixes: [#42](https://github.com/grifferz/pah-irc/issues/42), others.
* Typo fixes (Douglas Gardner): [#49](https://github.com/grifferz/pah-irc/pull/49)
* Typo fix (Paul Dart): [#33](http://github.com/grifferz/pah-irc/pull/41).

## v0.2
### 2015-02-18
* Fixed show-stopper bug [#34](http://github.com/grifferz/pah-irc/issues/34) where Black deck is never replenished once empty, causing same Black Card to be presented over and over.
* Fixed show-stopper bug [#37](http://github.com/grifferz/pah-irc/issues/37) where White Cards in the players' hands were also present in the deck after a reshuffle, causing database constraint violations.
* Fixed bug [#38](http://github.com/grifferz/pah-irc/issues/38) where Card Tsar could be forcibly resigned shortly after the play was completed, as the game's timer was not updated on a complete play.
* Add 'list' as alias of 'hand' (Dave Walker): [#36](http://github.com/grifferz/pah-irc/pull/36).
* Typo fixes: [#28](http://github.com/grifferz/pah-irc/issues/28), others.
* Typo fix (Paul Dart): [#33](http://github.com/grifferz/pah-irc/pull/33).
    
## v0.1
### 2015-02-17
* First kinda usable release (so I thought).
