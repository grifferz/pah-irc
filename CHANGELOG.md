# Change log

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
