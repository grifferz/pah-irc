# Perpetually Against Humanity, IRC Edition (pah-irc)

## What?

It's another IRC bot for playing Cards Against Humanity.

## Why?

There's quite a few IRC bots for this already, but it struck me that none of
them particularly played to IRC's strengths, those being:

*   Asynchronous, long-term associations between a slowly evolving group

    IRC channels tend to exist for a long time with a group of people that
    alters quite slowly. Your typical real-life game of CAH involves a bunch of
    people at a specific event for a limited amount of time. An IRC channel may
    exist for years.

    So why can't you play CAH for years, but slowly?

    And why not have the players able to come and go? That's a disaster for an
    in-person limited-time game, but not a big deal for something that's
    essentially going to go on forever. The bot should know whose turn it is to
    do what, and remind them when it next sees them.

*   Opportunity for more natural interaction with a program

    IRC bots don't have to be incredibly terse using commands with tons of
    syntax.  It should be possible to conduct a simple game using simple
    English language expressions on the part of the players.

*   Multiple things happening at once

    No reason why the bot can't be running games in multiple channels at once.
    Running extra copies is going to be a bit tedious.

## Installation

You can find the dependencies in the **cpanfile**, but you may find it simpler
to install them all into a local directory with **cpanminus**:

```
$ cpanm --local-lib=./pah-libs --installdeps .
```

Or if you'd rather use CPAN modules for everything that's not core Perl:

```
$ cpanm --local-lib-contained=./pah-libs --installdeps .
```

## Usage

Quite a few interactions with the bot will be fairly natural language and depend on context, for example:

> &lt;AgainstHumanity&gt; We need 3 more players to get this game started. Who
                          else wants to play? Say "AgainstHumanity: me" if
                          you'd like to join in.

> &lt;grifferz&gt; AgainstHumanity, me

> &lt;AgainstHumanity&gt; Great, you're in! 2 more players needed…

Which hopefully doesn't need to be documented.

### Public channel commands

Public channel commands should be addressed to the bot by just sending a
message to the channel with the bot's nickname as the first word. In the
documentation we'll assume that the bot's nickname is **AgainstHumanity**, so
for example:

> AgainstHumanity status

> AgainstHumanity: status

> AgainstHumanity, status

are all fine.

*   `status`

    Report the status of the game currently playing in the channel, if any.

    If a game is currently playing then this will say:

    *   Who we're waiting on (either to play their turn, or to pick the winner
        if they're the Card Tsar);

    *   The current text of the Black Card;

    *   The top three points-scorers in that game.

*   `start`

    Starts a new game of Perpetually Against Humanity. Players will need to be
    gathered first.

*   `deal me in`

    Join in to the currently-active game. You'll receive a hand at the next
    deal. If the game already has 20 players then you will need to wait until
    one of them resigns.

*   `resign`

    `deal me out`

    Resign from the currently-active game. Your scores will still be kept and
    you can join in to the game again later on. If this takes the number of
    active players below 4 then the game will be paused until someone joins
    again.

### Private commands

These commands can be given in private message to the bot. Against there are
some interactions that are more natural, in response to the state of the game.

Many commands optionally take a channel parameter. This is only needed if the
player is in more than one active game. That's fairly unlikely so most of the
time that can be left off and the bot will work it out.

*   `[#channel] black`

    Repeat the text of the current Black Card.

*   `[#channel] hand`

    Provides a numbered list of the White Cards in the player's hand.

*   `[#channel] play <number>`

    `[#channel] play <number> <number>`

    `[#channel] play <number>,<number>`

    `[#channel] play <number> and <number>`

    `[#channel] play <number> & <number>`

    Play the numbered White Card for this round. Some rounds require two White
    Cards, so they will be played in the order specified.

    The bot will repeat back to you the current Black Card and your proposed
    answer.

    The Card Tsar will not see any of the plays until all players have made
    their play; you may alter your play at any time up until then.

### Security

This bot is relying on the IRC network having IRC services and an IRCd that
exposes the identified status of the user in the WHOIS reply. Charybdis IRCd is
known to do this, so this should work on IRC networks like Freenode.

You will not be able to start a game nor participate in one unless you have a
registered nickname and are identified to it.

Should you drop or abandon your registered nickname and it is later registered
by someone else then they will be able to play games of Perpetually Against
Humanity as "you".

On a technical note this means that for every privileged command, the bot is
doing a WHOIS command and waiting for the response to see if the user is
actually identified to a nickname before it does anything with the command.
That may seem slow, but I took this approach in a previous bot (Enoch quote
bot) and it seemed to be unnoticeable. I'm prepared to add caching later if it
becomes a problem.

### Speed of play, or lack of it

If you haven't got the hint yet, the idea here is not to stress about games
being stormingly fast. They can just kind of happen in their own time. There
isn't any end.

What happens when someone ignores their responsibility though?

There's only two responsibilities in Perpetually Against Humanity:

* If you're the Card Tsar then you need to pick the winning play.
* If you're not the Card Tsar then you need to make your play.

If that doesn't happen in a reasonable amount of time—and for now we'll go with
48 hours being a reasonable amount of time—then the player responsible has
timed out of the game. For now we'll treat that like resigning.

For a Card Tsar that means:
1. The current round is abandoned
2. No one gets any Awesome Points
3. Any played White Cards go on the bottom of the deck
4. The Card Tsar's own hand goes on the bottom of the deck
5. If there's still at least 4 players, the next player becomes Card Tsar and
   play continues. Otherwise the game is paused until more players join.

For anyone else that means:
1. Their hand, including any White Cards played in the current round, go on the
   bottom of the deck.
2. If there's still at least 4 players then play continues, otherwise play is
   paused until more players join.

So, a person who goes unresponsive can hold up a game for a while, but games
aren't necessarily meant to be quick-fire anyway because *they are never going
to end*. Players who know they need to stop playing (e.g. because they aren't
going to be on IRC for a while) can be helpful by explicitly resigning.

### Card packs

This will be initially supplied with the UK edition of Cards Against Humanity
(because the first channels that will probably use it are UK-biased channels),
but a later release should support additional packs.
