# Perpetually Against Humanity, IRC Edition (pah-irc)

## What?

It's another IRC bot for playing [Cards Against Humanity™](http://www.cardsagainsthumanity.com/).

Cards Against Humanity is a trademark of Cards Against Humanity LLC.

[Wikipedia](http://en.wikipedia.org/wiki/Cards_Against_Humanity) describes it as

> a party game using cards. It is available as a free download that players can print to create their own cards, and also available to purchase in published hardcopy.

Learn more about it at [their web site](http://www.cardsagainsthumanity.com/).

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

## Usage

Quite a few interactions with the bot will be fairly natural language and
depend on context, for example:

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

    *   Who the current Card Tsar is.

    *   The text of the current Black Card;

*   `scores`

    `stats`

    Displays:

    *   Who's active in the game and what their scores are.

    *   The top three all-time points-scorers for this game, including ties.

*   `start`

    Starts a new game of Perpetually Against Humanity. Players will need to be
    gathered before it will actually proceed.

*   `dealmein`

    `deal me in`

    Join in to the currently-active game. You'll immediately receive a hand and
    a reminder of the current Black Card by private message. You can play your
    hand immediately.

    If the game already has 20 players then you will need to wait until
    one of them resigns.

    If the game now has enough players to start then it will start.

*   `resign`

    `dealmeout`

    `deal me out`

    `retire`

    Resign from the currently-active game. Your scores will still be kept and
    you can join in to the game again later on. If this takes the number of
    active players below 4 then the game will be paused until someone joins
    again.

    Your hand of White Cards including any White Cards you already played are
    discarded.

    If you are the current round's Card Tsar then play will move on without any
    Awesome Points being awarded. If the hand was complete (all players made
    their play and plays were announced in the channel) then these White Cards
    will be discarded and new White Cards drawn. Otherwise played White Cards
    will be returned to players' hands.

*   `winner <number>`

    `<number>`

    Used by the Card Tsar to indicate that the play numbered <number> is the
    one they think is best.

    This command can be simply abbreviated as a single digit, as it will be
    obvious from the context what is meant.

### Private commands

These commands can be given in private message to the bot. Again there are some
interactions that are more natural, in response to the state of the game.

Many commands optionally take a channel parameter. This is only needed if the
player is in more than one active game. That's fairly unlikely so most of the
time that can be left off and the bot will work it out.

*   `[#channel] status`

    Identical to the public `status` command, but in private in case you don't
    want to bother the channel with the output.

*   `[#channel] scores`

    `[#channel] stats`

    Identical to the public `scores` command, but in private in case you don't
    want to bother the channel with the output.

*   `[#channel] black`

    Repeat the text of the current Black Card.

*   `[#channel] hand`

    `[#channel] list`

    Provides a numbered list of the White Cards in the player's hand.

*   `[#channel] play <number>`

    `[#channel] play <number> <number>`

    `[#channel] play <number>,<number>`

    `[#channel] play <number> and <number>`

    `[#channel] play <number> & <number>`

    `<number>`

    `<number> <number>`

    Play the numbered White Card for this round. Some rounds require two White
    Cards, so they will be played in the order specified.

    The bot will repeat back to you the current Black Card and your proposed
    answer.

    You may alter your play as many times as you like until every active player
    has made their play, at which point the plays will be revealed to the
    channel and may not be changed.

    Where a channel will not be required, just saying one or two numbers
    (without the "play" prefix) is an acceptable shortcut.

*   `pronoun <pronoun>`

    By default the bot uses the "their" pronoun:

    * `<PAH>` dutchie: A game is active! We're just waiting on **dave2** to make their play.
    * […]
    * `<PAH>` 3 people just played! We're just waiting on **dg** to make their play.

    If you would prefer for the bot to use a different pronoun in relation to
    you, use this command to set it. This will apply in all games that you are
    in.

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

## Flooding

The game can be rather verbose, both in the channel and in private message to
players. If you aren't careful then the IRC server will probably flood-limit
the bot by dropping its messages or even disconnect it from the network.

The default bot configuration allows for a burst of 10 messages and thereafter
will send only one message per second until there has been a pause of 10
seconds again. This appears to be enough to avoid flood-limiting on networks
that use Charybdis or ircd-seven (e.g. Freenode).

Freenode IRC operators have told us that voicing the bot in a channel will
exempt it from some flood checks both to the channel and to users who share the
channel with the bot.

If you are in a position to further exempt the bot from flood limits (i.e. you
have access to the IRC server configuration, or know someone who will modify it
for you) then you can adjust the bot's own flood limiting by altering the
`msg_per_sec` and `msg_burst` configuration options.

## Security

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

## Restarting the bot

Pretty much all game state is kept in the database so it should be safe to kill
and restart the bot at any time.

## Speed of play, or lack thereof

If you haven't got the hint yet, the idea here is not to stress about games
being very slow-moving. They can just kind of happen in their own time. There
isn't any end.

What happens when someone ignores their responsibility though? At the moment
we're trying forced resignations after a timeout (the `turnclock` in the config
file).

There's only two responsibilities in Perpetually Against Humanity:

* If you're the Card Tsar then you need to pick the winning play.
* If you're not the Card Tsar then you need to make your play.

If that doesn't happen in a reasonable amount of time—and for now we'll go with
24 hours being a reasonable amount of time—then the player responsible has
timed out of the game. For now we'll treat that like resigning.

For a Card Tsar that means:

1. The current round is abandoned
2. No one gets any Awesome Points
3. Any played White Cards will be discarded.
4. The Card Tsar's own hand is discarded.
5. If there's still at least 4 players, the next player becomes Card Tsar and
   play continues. Otherwise the game is paused until more players join.

For anyone else that means:

1. The White Cards in their hand, including any White Cards played in the
   current round, are discarded.
2. If there's still at least 4 players then play continues, otherwise play is
   paused until more players join.

So, a person who goes unresponsive can hold up a game for a while, but games
aren't necessarily meant to be quick-fire anyway because *they are never going
to end*. Players who know they need to stop playing (e.g. because they aren't
going to be on IRC for a while) can be helpful by explicitly resigning.

## Card packs

This will be initially supplied with the UK edition of Cards Against Humanity
(because the first channels that will probably use it are UK-biased channels),
but a later release should support additional packs.

## License

This IRC bot is made available under the Artistic License, the same as Perl itself.

Cards Against Humanity card content is used under a [Creative Commons BY-NC-SA license](https://creativecommons.org/licenses/by-nc-sa/2.0/).

## Bugs

Undoubtedly many.

I don't really know what I am doing, programming-wise, but I know at least that
having a single module file with 3,100 lines in it is not sane.

So, I'd appreciate any bug reports, assistance or advice. Please be gentle!

Issues can be [reported on github](https://github.com/grifferz/pah-irc/issues).
