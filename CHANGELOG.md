# Change log

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
