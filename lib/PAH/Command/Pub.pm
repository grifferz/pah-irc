package PAH::Command::Pub;

=pod
The commands that can be received from IRC in a public channel.

Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

Artistic license same as Perl.
=cut

use utf8;

use PAH::Log;

sub scores {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $irc     = $self->_irc;

    my $channel = $self->db_get_channel($chan);

    # It shouldn't be possible to not have a Channel row, because we wouldn't
    # be inside the channel if we didn't know about it.
    if (not defined $channel) {
        $irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
            . " a weird error that needs to be reported!");
        return;
    }

    my $game = $channel->rel_game;

    # How long ago did we last do this?
    my $now = time();

    if (defined $game and defined $self->_last->{$game->id}
            and defined $self->_last->{$game->id}->{scores}) {
        my $last_scores = $self->_last->{$game->id}->{scores};

        if (($now - $last_scores) <= 60) {
        # Last time we did scores in this channel was 60 seconds ago or less.
            debug("%s tried to display scores for %s but it was already done %u"
                . " secs ago; ignoring", $who, $chan, ($now - $last_scores));
            $irc->msg($chan,
                sprintf("$who: Sorry, I'm ignoring your scores command"
                    . " because I did one just %u secs ago.",
                    ($now - $last_scores)));
            return;
        }

        # Record timestamp of when we did this.
        $self->_last->{$game->id}->{scores} = $now;
    }

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($chan, $chan, $who);
        return;
    }

    # Game is either running or gathering players.
    $self->report_game_scores($game, $chan);
}

sub status {
    my ($self, $args) = @_;

    my $chan   = $args->{chan};
    my $who    = $args->{nick};
    my $schema = $self->_schema;
    my $irc    = $self->_irc;

    my $channel = $self->db_get_channel($chan);

    # It shouldn't be possible to not have a Channel row, because we wouldn't
    # be inside the channel if we didn't know about it.
    if (not defined $channel) {
        $irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
           . " a weird error that needs to be reported!");
       return;
    }

    my $game = $channel->rel_game;

    # How long ago did we last do this?
    my $now = time();

    if (defined $game and defined $self->_last->{$game->id}
            and defined $self->_last->{$game->id}->{status}) {
        my $last_status = $self->_last->{$game->id}->{status};

        if (($now - $last_status) <= 120) {
        # Last time we did status in this channel was 120 seconds ago or less.
            debug("%s tried to display status for %s but it was already done %u"
               . " secs ago; ignoring", $who, $chan, ($now - $last_status));
            $irc->msg($chan,
                sprintf("$who: Sorry, I'm ignoring your status command"
                    . " because I did one just %u secs ago.",
                    ($now - $last_status)));
            return;
        }
    }

    # Record timestamp of when we did this.
    if (defined $game) {
        $self->_last->{$game->id}->{status} = $now;
    }

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($chan, $chan, $who);
    } elsif (2 == $game->status) {
        $self->report_game_status($game, $chan);
    } elsif (1 == $game->status) {
        my $num_players = $game->rel_active_usergames->count;
        my $my_nick     = $irc->nick();

        # Game is still gathering players. Give different response depending on
        # whether they are already in it or not.
        my $ug = $self->db_get_nick_in_game($who, $game);

        if (defined $ug) {
            $irc->msg($chan,
                sprintf("%s: A game exists but we only have %u player%s"
                   . " (%s). Find me %u more and we're on.", $who,
                   $num_players, 1 == $num_players ? '' : 's',
                   1 == $num_players ? 'you' : 'including you',
                   4 - $num_players));
            $irc->msg($chan,
                qq{Any takers? Just type "$my_nick: me" and you're in.});
        } else {
            $irc->msg($chan,
                sprintf("%s: A game exists but we only have %u player%s."
                    . " Find me %u more and we're on.", $who, $num_players,
                    1 == $num_players ? '' : 's', 4 - $num_players));
            $irc->msg($chan,
                qq{$who: How about you? Just type "$my_nick: me" and you're}
                . qq{ in.});
        }
    } elsif (0 == $game->status) {
        $irc->msg($chan,
            "$who: The game is paused but I don't know why! Report this!");
    } else {
        debug("Game for %s has an unexpected status (%u)", $chan,
            $game->status);
        $irc->msg($chan,
            "$who: I'm confused about the state of the game, sorry. Report"
           . " this!");
    }
}

# A user wants to join a (presumably) already-running game. This can happen
# from either of the following scenarios:
#
# <foo> AgainstHumanity: start
# <AgainstHumanity> foo: You're on! We have a game of Perpetually Against
#                   Humanity up in here. 4 players minimum are required. Who
#                   else wants to play?
# <AgainstHumanity> Say "AgainstHumanity: me" if you'd like to!
# <bar> AgainstHumanity: me!
#
# or:
#
# <bar> AgainstHumanity: deal me in.
sub dealin {
    my ($self, $args) = @_;

    my $irc     = $self->_irc;
    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel."
           . " That's weird and shouldn't happen. Report this!");
        return;
    }

    my $game = $channel->rel_game;

    debug("%s wants to join game at %s", $who, $chan);

    # Is there a game running already?
    if (not defined $game) {
        # No, there is no game.
        #
        # This raises the question of whether we should treat a user asking to
        # be dealt in to a non-existent game as request to start the game
        # itself.
        #
        # I'm leaning towards "no" because the fact that the channel doesn't
        # already have a game running may hint towards the norms of the channel
        # being that games aren't welcome.
        debug("There's no game at %s for %s to join", $chan, $who);
        $irc->msg($chan,
            "$who: Sorry, there's no game here to deal you in to. Want to start"
           . " one?");
        $irc->msg($chan, qq{$who: If so, type "$my_nick: start"});
        return;
    }

    my $user = $self->db_get_user($who);

    my @active_usergames = $game->rel_active_usergames;

    # Are they already in it?
    if (defined $game->rel_active_usergames
            and grep $_->user == $user->id, @active_usergames) {
        debug("%s is already playing in game at %s", $who, $chan);
        $irc->msg($chan, "$who: Heyyy, you're already playing!");
        return;
    }

    # Is the game's current round complete (waiting on Card Tsar)? If so then no
    # new players can immediately join, because then everyone would know who
    # the extra play was from. They will be dealt in to the next hand.
    if (2 == $game->status and $self->round_is_complete($game)) {
        debug("%s can't immediately join game at %s because the round is"
           . " complete", $who, $chan);

        my $tsar      = $game->rel_tsar_usergame->rel_user;
        my $tsar_nick = do {
            if (defined $tsar->disp_nick) { $tsar->disp_nick }
            else                          { $tsar->nick }
        };

        my $joinq = $self->_joinq;

        $joinq->push(
            {
                user => $user,
                game => $game,
            }
        );

        $irc->msg($chan,
            sprintf("%s: Sorry, this round is complete and we're waiting on"
               . " %s to pick the winner. Stay on IRC and you'll be dealt"
               . " in to the next round automatically.", $who, $tsar_nick));
        return;
    }

    # Maximum 20 players in a game.
    my $num_players = scalar @active_usergames;

    if ($num_players >= 20) {
        debug("%s can't join game at %s because there's already %s players",
            $who, $chan, $num_players);
        $irc->msg($chan,
            "$who: Sorry, there's already $num_players players in this game and"
           . " that's the maximum. Try again once someone has resigned!");
        return;
    }

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    my $usergame = $self->add_user_to_game(
        {
            user => $user,
            game => $game,
        }
    );

    $irc->msg($chan, "$who: Nice! You're in!");

    # Does the game have enough players to start yet?
    $num_players = $game->rel_active_usergames->count;

    if ($num_players >= 4 and 1 == $game->status) {
        debug("Game at %s now has enough players to proceed", $chan);

        $game->status(2);
        $game->activity_time(time());
        $game->update;

        my $prefix;

        if (defined $game->bcardidx) {
            # This game already had some rounds so it has been unpaused.
            $prefix = 'The game is on again!';
        } else {
            # This game has never had any rounds before; this is a new game.
            $prefix = 'The game begins!';
        }

        $irc->msg($chan,
            "$prefix Give me a minute or two to tell everyone their hands"
           . " without flooding myself off, please.");

        # Get a chat window open with all the players.
        $self->brief_players($game);
        # Top everyone's White Card hands up to 10 cards.
        $self->topup_hands($game);
        # And deal out a Black Card to the Tsar, if necessary.
        if (not defined $game->bcardidx) {
            $self->deal_to_tsar($game);
        } else {
            $irc->msg($chan, "Current Black Card:");
            $self->notify_bcard($chan, $game);
        }
    } elsif (1 == $game->status) {
        debug("Game at %s still requires %u more players", $chan,
            4 - $num_players);
        $irc->msg($chan,
            "We've now got $num_players of minimum 4. Anyone else?");
        $irc->msg($chan, qq{Type "$my_nick: me" if you'd like to play too.});
    } elsif (2 == $game->status) {
        # They joined an already-running game, so they need a hand of
        # White Cards.
        $self->topup_hand($usergame);

        # And to know what the Black Card is.
        $irc->msg($who, "Current Black Card:");
        $self->notify_bcard($who, $game);
    }
}

# User wants to start a new game in a channel.
sub start {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $my_nick = $self->_irc->nick();
    my $irc     = $self->_irc;
    my $schema  = $self->_schema;

    # Do we have a channel in the database yet? The only way to create a
    # channel is to be invited there, so there will not be any need to create
    # it here, and it's a weird error to not have it.
    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
           . " a weird error that needs to be reported!");
       return;
    }

    # Is there already a game for this channel?
    my $game = $channel->rel_game;

    if (defined $game) {
        # There's already a Game for this Channel. It could be in one of three
        # possible states:
        #
        # 0: Paused for an unknown reason.
        # 1: Waiting for a sufficient number of players.
        # 2: Running.
        #
        # Whatever the case, this is not the place where it can be started:
        #
        # * Paused games should be started as soon as the bot joins a welcoming
        #   channel.
        #
        # * Games without enough players will start as soon as they get enough
        #   players.
        #
        # * Running games don't need to be started!
        #
        # So apart from explanatory messages this isn't going to do anything.
        my $status = $game->status;

        if (0 == $status) {
            $irc->msg($chan,
                "$who: Sorry, there's already a game for this channel, though"
               . " it seems to be paused when it shouldn't be! Ask around?");
        } elsif (1 == $status) {
            my $count = $game->rel_active_usergames->count;

            $irc->msg($chan,
                "$who: Sorry, there's already a game here but we only have"
               . " $count of minimum 4 players. Does anyone else want to"
               . " play?");
            $irc->msg($chan, qq{Type "$my_nick: me" if you'd like to!});
        } elsif (2 == $status) {
            $irc->msg($chan,
                "$who: Sorry, there's already a game running here!");
        }

        return;
    }

    # Need to create a new Game for this Channel. The User corresponding to the
    # nickname will be its first player. The initial status of the game will be
    # "waiting for players."
    $game = $schema->resultset('Game')->create(
        {
            channel       => $channel->id,
            create_time   => time(),
            activity_time => time(),
            status        => 1,
        }
    );

    # Seems to be necessary in order to get the default DB values back into the
    # object.
    $game->discard_changes;

    # Stuff the cards from memory structure into the database so that this game
    # has its own unique deck to work through, that will persist across process
    # restarts.
    $self->db_populate_cards($game, 'Black');
    $self->db_populate_cards($game, 'White');

    my $user = $self->db_get_user($who);

    # "Let the User see the Game!" Ahem. Add the User to the Game as the Tsar.
    # In the absence of being able to know who pooped last, the starting user
    # will be the first Card Tsar.
    my $usergame = $self->add_user_to_game({
            user => $user,
            game => $game,
            tsar => 1
        }
    );

    # Now tell 'em.
    $irc->msg($chan,
        "$who: You're on! We have a game of Perpetually Against Humanity up in"
       . " here. 4 players minimum are required. Who else wants to play?");
    $irc->msg($chan,
        qq{Say "$my_nick: me" if you'd like to!});
}

# A user wants to resign from the game. If they are the current round's Card
# Tsar then they aren't allowed to resign. Otherwise, their White Cards
# (including any that were already played in this round) are discarded and they
# are removed from the running game.
#
# If this brings the number of players below 4 then the game will be paused.
#
# The player can rejoin the game at a later time.
sub resign {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();
    my $irc     = $self->_irc;

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel."
           . " That's weird and shouldn't happen. Report this!");
        return;
    }

    my $game = $channel->rel_game;

    debug("%s attempts to resign from game in %s", $who, $chan);

    # Is there a game actually running?
    if (not defined $game) {
        debug("%s can't resign from non-existent game in %s", $who, $chan);
        $irc->msg($chan, "$who: There isn't a game running at the moment.");
        return;
    }

    my $user = $self->db_get_user($who);

    my $usergame = $schema->resultset('UserGame')->find(
        {
            'user' => $user->id,
            'game' => $game->id,
        },
    );

    # Is the user active in the game?
    if (not defined $usergame or 0 == $usergame->active) {
        # No.
        debug("%s tried to resign from game in %s but they weren't active",
            $who, $chan);
        $irc->msg($chan, "$who: You're not playing!");
        return;
    }

    $irc->msg($chan, "$who: Okay, you've been dealt out of the game.");
    $irc->msg($chan,
        qq{$who: If you want to join in again later then type}
        . qq{ "$my_nick: deal me in"});

    $self->resign($usergame);
}

# User wants to pick a winning play.
sub winner {
    my ($self, $args) = @_;

    my $irc     = $self->_irc;
    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $winner  = $args->{params};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();

    # winner needs to exist and be a single positive integer.
    if (not defined $winner or $winner !~ /^\d+$/ or $winner < 1) {
        $irc->msg($chan,
            qq{$who: What? You need to give me a single number, e.g.}
           . qq{ "$my_nick: winner 1"});
       return;
   }

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel."
            . " That's weird and shouldn't happen. Report this!");
        return;
    }

    my $game = $channel->rel_game;

    # Is there even a game?
    if (not defined $game) {
        $irc->msg($chan, "$who: What? There's no game running here yet.");
        return;
    }

    # Is the game active?
    if ($game->status != 2) {
        $irc->msg($chan, "$who: Sorry, the game isn't active right now.");

        # Maybe it needs more players.
        if (1 == $game->status) {
            my $num_players = $game->rel_active_usergames->count;

            $irc->msg($chan,
                sprintf("We need %u more player%s before we can start"
                   . " playing.", 4 - $num_players,
                   (4 - $num_players) == 1 ? '' : 's'));
        }

        return;
    }

    # Are they the Card Tsar?
    my $user = $self->db_get_user($who);

    if (not $self->user_is_tsar($user, $game)) {
        my $tsar      = $game->rel_tsar_usergame->rel_user;
        my $tsar_nick = $tsar->disp_nick;

        $tsar_nick = $tsar->nick if (not defined $tsar_nick);

        $irc->msg($chan,
            sprintf("%s: Sorry, you're not the Card Tsar – that's %s.",
                $who, $tsar_nick));
        return;
    }

    # Is the round actually complete?
    if (not $self->round_is_complete($game)) {
        $irc->msg($chan,
            "$who: Sorry, not everyone has played their hand yet!");
        $irc->msg($chan, $self->build_waitstring($game));
        return;
    }

    my $tally = $self->_plays->{$game->id};

    foreach my $uid (keys %{ $tally }) {
        if ($tally->{$uid}->{seq} == $winner) {
            # Found the winning play.
            my $winuser = $schema->resultset('User')->find(
                {
                    id => $uid,
                }
            );

            $game->rel_tsar_usergame->activity_time(time());
            $game->rel_tsar_usergame->update;

            my $win_ug = $self->end_round($winuser, $game);
            $self->cleanup_plays($game);
            $self->pick_new_tsar($win_ug, $tally->{$uid}->{play}, $game);
            $self->topup_hands($game);
            $self->clear_pokes($game);
            return;
        }
    }

    # If we got here then they gave us a winner number that doesn't exist in
    # the plays.
    $irc->msg($chan,
        "$who: Sorry, I don't seem to have a record of a play with that"
       . " number.");
}

# User wants to call up a list of plays for the completed hand.
sub plays {
    my ($self, $args) = @_;

    my $irc     = $self->_irc;
    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $my_nick = $irc->nick();

    my $channel = $self->db_get_channel($chan);

    # It shouldn't be possible to not have a Channel row, because we wouldn't
    # be inside the channel if we didn't know about it.
    if (not defined $channel) {
        $irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
            . " a weird error that needs to be reported!");
        return;
    }

    my $game = $channel->rel_game;

    # How long ago did we last do this?
    my $now = time();

    if (defined $game and defined $self->_last->{$game->id}
            and defined $self->_last->{$game->id}->{plays}) {
        my $last_plays = $self->_last->{$game->id}->{plays};

        if (($now - $last_plays) <= 120) {
            # Last time we did plays in this channel was 120 seconds ago or
            # less.
            debug("%s tried to display plays for %s but it was already done %u"
                . " secs ago; ignoring", $who, $chan, ($now - $last_plays));
            $irc->msg($chan,
                sprintf("$who: Sorry, I'm ignoring your plays command"
                    . " because I did one just %u secs ago.",
                    ($now - $last_plays)));
            return;
        }
    }

    # Record timestamp of when we did this.
    if (defined $game) {
        $self->_last->{$game->id}->{plays} = $now;
    }

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($chan, $chan, $who);
    } else {
        $self->report_plays($game, $chan);
    }
}

1;
