package PAH::Command::Priv;

=pod
The commands that can be received from IRC in a private message.

Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

Artistic license same as Perl.
=cut

use warnings;
use strict;
use utf8;

use PAH::Log;

use List::Util qw/reduce/;
use Scalar::Util qw/looks_like_number/;

sub scores {
    my ($self, $args) = @_;

    my $who = $args->{nick};
    my $irc = $self->_irc;

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $channel = undef;

    if (not defined $chan) {
        $channel = $self->guess_channel($who);

        if (defined $channel) {
            $chan = $channel->disp_name;
        }
    } else {
        # They specified a channel, so try to get that one.
        $channel = $self->db_get_channel($chan);

        if (not defined $channel) {
            $chan = undef;
        }
    }

    # By now we either:
    #
    # 1. Guessed the channel and have a channel object in $channel, channel
    #    name in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in
    #    $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so
    #    $channel is undef.
    if (not defined $channel) {
        # Cases 2 or 4.
        if (defined $chan) {
            # They specified the channel but it didn't exist (#4). Probably bot
            # has never been in it.
            debug("%s asked for scores of game in %s but I don't know anything"
               . " about %s", $who, $chan, $chan);
            $irc->msg($who, "Sorry, I have no knowledge of $chan.");
            return;
        }

        # It's case #2.
        debug("%s asked for game scores but I couldn't work out which channel"
            . " they were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested}
            . qq{ in. Try again with "#channel scores".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($who, $chan);
        return;
    }

    $self->report_game_scores($game, $who);
}

sub status {
    my ($self, $args) = @_;

    my $who = $args->{nick};
    my $irc = $self->_irc;

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $channel = undef;

    if (not defined $chan) {
        $channel = $self->guess_channel($who);

        if (defined $channel) {
            $chan = $channel->disp_name;
        }
    } else {
        # They specified a channel, so try to get that one.
        $channel = $self->db_get_channel($chan);

        if (not defined $channel) {
            $chan = undef;
        }
    }

    # By now we either:
    #
    # 1. Guessed the channel and have a channel object in $channel, channel
    #    name in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in
    #    $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so
    #    $channel is undef.
    if (not defined $channel) {
        # Cases 2 or 4.
        if (defined $chan) {
            # They specified the channel but it didn't exist (#4). Probably bot
            # has never been in it.
            debug("%s asked for status of game in %s but I don't know anything"
               . " about %s", $who, $chan, $chan);
            $irc->msg($who, "Sorry, I have no knowledge of $chan.");
            return;
        }

        # It's case #2.
        debug("%s asked for game status but I couldn't work out which channel"
            . " they were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested}
            . qq{ in. Try again with "#channel status".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($who, $chan);
    } elsif (2 == $game->status) {
        $self->report_game_status($game, $who);
    } elsif (1 == $game->status) {
        my $num_players = $game->rel_active_usergames->count;

        # Game is still gathering players. Give different response depending on
        # whether they are already in it or not.
        my $ug = $self->db_get_nick_in_game($who, $game);

        if (defined $ug and 1 == $ug->active) {
            $irc->msg($who,
                sprintf("A game exists in %s but we only have %u"
                    . " player%s (%s). Find me %u more and we're on.",
                    $chan, $num_players, 1 == $num_players ? '' : 's',
                    1 == $num_players ? 'you' : 'including you',
                    4 - $num_players));
        } else {
            $irc->msg($who,
                sprintf("A game exists in %s but we only have %u"
                    . " player%s. Find me %u more and we're on.", $chan,
                    $num_players, 1 == $num_players ? '' : 's',
                    4 - $num_players));
        }
    } elsif (0 == $game->status) {
        $irc->msg($who,
            "The game in $chan is paused but I don't know why!"
            . " Report this!");
    } else {
        debug("Game for %s has an unexpected status (%u)", $chan,
            $game->status);
        $irc->msg($who,
            "I'm confused about the state of the game in $chan, sorry!"
            . " Report this!");
    }
}

# Someone is asking for their current hand (of White Cards) to be displayed.
#
# First assume that they are only in one game so the channel will be implicit.
# If this proves to not be the case then ask them to try again with the channel
# specified.
sub hand {
    my ($self, $args) = @_;

    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $my_nick = $self->_irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    # Only players active in at least one game will have a hand at all, so
    # check that first.
    my @active_usergames = $user->rel_active_usergames;

    # Did they specify a channel? If so then discard any active games that are
    # not for that channel.
    if (defined $chan) {
        @active_usergames = grep {
            $_->rel_game->rel_channel->name eq $chan
        } @active_usergames;
    }

    my $game_count = scalar @active_usergames;

    if (1 == $game_count) {
        my $ug    = $active_usergames[0];
        my @cards = $ug->rel_usergamehands;

        # Sort them by "pos".
        @cards = sort { $a->pos <=> $b->pos } @cards;

        $self->_irc->msg($who,
            "Your White Cards in " . $ug->rel_game->rel_channel->disp_name
            . ":");
        $self->notify_wcards($ug, \@cards);
    } elsif (0 == $game_count) {
        if (defined $chan) {
            $self->_irc->msg($who,
                "Sorry, you don't appear to be active in a game in $chan yet.");
        } else {
            $self->_irc->msg($who,
                "Sorry, you don't appear to be active in any games yet.");
        }

        $self->_irc->msg($who,
            "If you'd like to start one then type \"$my_nick: start\" in the"
           . " channel you'd like to play in.");
        $self->_irc->msg($who,
            "Or you can join a running game with \"$my_nick: deal me in\".");
    } else {
        # Can only get here if they did not specify a channel. If they *had*
        # specified a channel then there would only have been one item in
        # @active_usergames. So we need to ask them to specify.
        my @channels = map {
            $_->rel_game->rel_channel->name
        } @active_usergames;

        my $last            = pop @channels;
        my $channels_string = join(', ', @channels) . ", and $last";

        $self->_irc->msg($who,
            "Sorry, you appear to be active in games in $channels_string.");
        $self->_irc->msg($who,
            "You're going to have to be more specific! Type \"$last hand\" for"
           . " example.");
    }

}

# Tell a user the text of the current black card.
#
# A complication here is that this command can be called by anyone, so they may
# not be an active player or even be a player at all.
#
# If they are an active player in just one game then we know what channel this
# relates to, but if no channel is specified and they're not active or are
# active in multiple then we'll need to ask them to specify.
sub black {
    my ($self, $args) = @_;

    my $irc     = $self->_irc;
    my $schema  = $self->_schema;
    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $my_nick = $self->_irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $game;

    # Try to work out which Game we should be operating on here.
    if (defined $chan) {
        # They specified a channel. Is there a game for that channel?
        my $channel = $schema->resultset('Channel')->find({ name => $chan });

        if (not defined $channel) {
            # Can't be a game there, then.
            $irc->msg($who, sprintf("There's no game running in %s!", $chan));
            return;
        }

        $game = $channel->rel_game;
    } else {
        my @active_usergames = $user->rel_active_usergames;

        my $game_count = scalar @active_usergames;

        if (1 == $game_count) {
            # Simplest case: they are an active player in one game.
            $game = $active_usergames[0]->rel_game;
            $chan = $game->rel_channel->disp_name;
        } elsif (0 == $game_count) {
            # They aren't active in any game, and they didn't specify a
            # channel, so no way to know which channel they meant.
            $irc->msg($who,
                "Sorry, you're going to have to tell me which channel's game"
               . " you're interested in.");
            $irc->msg($who, qq{Try again with "/msg $my_nick #channel black"});
            return;
        } else {
            # They're in more than one game so again no way to tell which one
            # they mean.
            $irc->msg($who,
                "Sorry, you appear to be in multiple games so you're going to"
               . " have to specify which one you mean.");
            $irc->msg($who, qq{Try again with "/msg $my_nick #channel black"});
            return;
        }
    }

    if (not defined $game) {
        # Shouldn't be possible to get here without a Game.
        debug("Somehow ended up without a valid Game object");
        return;
    }

    if ($game->status != 2) {
        # There is a game but it's not running.
        $irc->msg($who, "The game in $chan is currently paused.");
        return;
    }

    $irc->msg($who, "Current Black Card for game in $chan:");
    $self->notify_bcard($who, $game);

    my @active_usergames = $game->rel_active_usergames;
    my ($usergame) = grep { $_->rel_user->id == $user->id } @active_usergames;
    my ($tsar)     = grep { 1 == $_->is_tsar } @active_usergames;

    my $tsar_user = $tsar->rel_user;

    if ((defined $tsar_user->disp_nick and $tsar_user->disp_nick eq $who)
            or ($tsar_user->nick eq $who)) {
        # They're the Card Tsar.
        $irc->msg($who, "You're the current Card Tsar!");
    } else {
        my $tsar      = $tsar->rel_user;
        my $tsar_nick = $tsar->disp_nick;

        $tsar_nick = $tsar->nick if (not defined $tsar_nick);

        $self->_irc->msg($who,
            sprintf("The current Card Tsar is %s.", $tsar_nick));

        # Are they in a position to play a move?
        if (defined $usergame) {
            $irc->msg($who, qq{Use the "Play" command to make your play!});
        }
    }

}

# A user wants to make a play from their hand of White Cards. After sanity
# checks we'll take the play and then repeat it back to them so they can
# appreciate the full impact of their choice.
#
# They can make another play at any time up until when the Card Tsar views the
# cards.
sub play {
    my ($self, $args) = @_;

    my $who     = $args->{nick};
    my $params  = $args->{params};
    my $user    = $self->db_get_user($who);
    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    # Only players active in at least one game will have a hand at all, so
    # check that first.
    my @active_usergames = $user->rel_active_usergames;

    # Did they specify a channel? If so then discard any active games that are
    # not for that channel.
    if (defined $chan) {
        @active_usergames = grep {
            $_->rel_game->rel_channel->name eq $chan
        } @active_usergames;
    }

    my $game_count = scalar @active_usergames;

    if (0 == $game_count) {
        $irc->msg($who, "You aren't currently playing a game with me!");
        $irc->msg($who,
            qq{You probably want to be typing "$my_nick: start" or}
           . qq{ "$my_nick: deal me in" in a channel.}, $my_nick, $my_nick);
        return;
    } elsif ($game_count > 1) {
        # Can only get here when the channel is not specified.
        # Since they're in multiple active games we need to ask them to specify
        # which game they intend to make a play for.
        $irc->msg($who,
            "Sorry, you're in multiple active games right now so I need you to"
           . " specify which channel you mean.");
        $irc->msg($who,
            qq{You can do that by typing "/msg $my_nick #channel play …"});
        return;
    }

    # Finally we've got the specific UserGame for this player and channel.
    my $ug      = $active_usergames[0];
    my $game    = $ug->rel_game;
    my $channel = $game->rel_channel;

    # Is the game actually active?
    if ($game->status != 2) {
        $irc->msg($who,
            sprintf("Sorry, the game in %s isn't active at the moment, so no"
               . " plays are being accepted.", $channel->disp_name));
        return;
    }

    # Is there already a full set of plays for this game? If so then no more
    # changes are allowed.
    if ($self->round_is_complete($game)) {
        my $tsar_user = $game->rel_tsar_usergame->rel_user;
        my $tsar_nick = do {
            if (defined $tsar_user->disp_nick) { $tsar_user->disp_nick }
            else                               { $tsar_user->nick }
        };

        $irc->msg($who,
            sprintf("All plays have already been made for this game, so no"
               . " changes now! We're now waiting on the Card Tsar (%s).",
               $tsar_nick));
        return;
    }

    # Are they the Card Tsar? The Tsar doesn't get to play!
    if (1 == $ug->is_tsar) {
        $irc->msg($who,
            sprintf("You're currently the Card Tsar for %s; you don't get to"
               . " play any White Cards yet!", $channel->disp_name));
       return;
    }

    # Does their play even make sense?
    my ($first, $second);

    my $bcardidx     = $game->bcardidx;
    my $cards_needed = $self->how_many_blanks($game, $bcardidx);

    if (not defined $params or 0 == length($params)) {
        if (1 == $cards_needed) {
            $irc->msg($who,
                qq{I need one answer and you've given me none! Try}
               . qq{ "/msg $my_nick play 1" where "1" is the White Card}
               . qq{ number from your hand.});
        } else {
            $irc->msg($who,
                qq{I need two answers and you've given me none! Try}
               . qq{ "/msg $my_nick play 1 2" where "1" and "2" are the White}
               . qq{ Card numbers from your hand.});
        }
        return;
    }

    if (1 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*$/ and $1 > 0) {
            $first = $1;
        } else {
            $irc->msg($who,
                qq{Sorry, this Black Card needs one White Card and "$params"}
               . qq{ doesn't look like a single, positive integer. Try}
               . qq{ again!});
            return;
        }
    } elsif (2 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*(?:\s+|,|\&)\s*(\d+)\s*$/
                and $1 > 0 and $2 > 0) {
            $first  = $1;
            $second = $2;
        } else {
            $irc->msg($who,
                "Sorry, this Black Card needs two White Cards. Do it like"
               . " this:");
            $irc->msg($who, qq{/msg $my_nick play 1 2});
            return;
        }

        if ($first == $second) {
            debug("%s tried to play two identical cards.", $who);
            $irc->msg($who,
                "You must play two different cards! Try again.");
            return;
        }
    } else {
        debug("Black Card with index %u appears to need %u answers,"
           . " which is weird.", $bcardidx, $cards_needed);
        return;
    }

    my $play;
    my @cards;

    if (1 == $cards_needed) {
        my $first_ugh = $self->db_get_nth_wcard($ug, $first);

        debug("%s plays their #%u card", $who, $first);
        push(@cards, $first_ugh);
    } else {
        my $first_ugh  = $self->db_get_nth_wcard($ug, $first);
        my $second_ugh = $self->db_get_nth_wcard($ug, $second);

        debug("%s plays their #%u and #%u cards", $who, $first, $second);
        push(@cards, ($first_ugh, $second_ugh));
    }

    # Have they tried to play a card that isn't in their hand?
    foreach my $ugh (@cards) {
        if (not defined $ugh) {
            debug("%s tried to play a card that wasn't in their hand", $who);

            my $hand_count = $self->count_cards($ug);
            $irc->msg($who,
                "Sorry, that card doesn't seem to be in your hand. Your hand is"
               . " numbered 1 – $hand_count.");

            return;
        }
    }

    $irc->msg($who,
        sprintf("Thanks. So this is your play for %s:",
            $channel->disp_name));

    $play = $self->build_play($ug, $bcardidx, \@cards);

    foreach my $line (split(/\n/, $play)) {
        # Sometimes YAML leaves us with a trailing newline in the text.
        next if ($line =~ /^\s*$/);

        $irc->msg($who, "→ $line");
    }

    # Record the play in this game's tally.
    my $is_new = 1;

    my @ugh_ids = map { $_->id } @cards;

    if (defined $self->_plays and defined $self->_plays->{$game->id}
            and defined $self->_plays->{$game->id}->{$user->id}) {
        $is_new = 0;
    }

    $self->_plays->{$game->id}->{$user->id} = {
        ugh_ids  => \@ugh_ids,
        play     => $play,
        notified => 0,
    };

    $self->write_tallyfile;

    $ug->activity_time(time());
    $ug->update;

    # Tell the channel that the user has made their play.
    if ($self->round_is_complete($game)) {
        # Kill any timer that might be about to notify of plays.
        undef $self->_pn_timers->{$game->id};

        $irc->msg($channel->name, "All plays are in. No more changes!");

        $self->prep_plays($game);

        $game->activity_time(time());
        $game->update;

        # Tell the channel about the collection of plays.
        $self->list_plays($game, $channel->name);

    } elsif ($is_new) {
        # Only bother to tell the channel if this is a new play.
        # User can then keep changing their play without spamming the channel.

        # Start a timer to notify about plays, as long as there isn't already a
        # timer running.
        #
        # The timer is 1/60th of the turnclock, minimum 60 seconds, maximum 30
        # minutes.
        my $after = $self->_config->{turnclock} / 60;

        if ($after > 1800) {
            $after = 1800;
        } elsif ($after < 60) {
            $after = 60;
        }

        if (not defined $self->_pn_timers->{$game->id}) {
            $self->_pn_timers->{$game->id} = AnyEvent->timer(
                after => $after,
                cb    => sub { $self->notify_plays($game); },
            );
        }
    }
}

# User wants to query or set personal configuration.
sub config {
    my ($self, $args) = @_;

    my $params  = $args->{params};
    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $setting = $user->rel_setting;
    my $irc     = $self->_irc;

    $setting = $self->db_create_usetting($user) if (not defined $setting);

    # If they didn't specify any config key then just list off the current
    # settings of all config keys.
    if (not defined $params or $params =~ /^\s*$/) {
        $irc->msg($who, "Your configuration:");

        my @keys = qw/chatpoke pronoun/;

        my $longest = reduce { length($a) > length($b) ? $a : $b } @keys;
        my $key_len = length($longest);

        foreach my $key (@keys) {
            my $val = $setting->$key;

            if ($key eq 'pronoun' and not defined $val) {
                $val = "their";
            }

            if (not defined $val) {
                $val = "";
            } elsif (looks_like_number($val)) {
                if (0 == $val) {
                    $val = "Off";
                } else {
                    $val = "On";
                }
            }

            $irc->msg($who, sprintf("  %-${key_len}s  %s", uc($key), $val));
        }

        return;
    }

    # $params contains something, so parse it into key and value.
    my ($key, $val) = split(/\s+/, $params);

    my $conf_args = {
        nick   => $who,
        user   => $user,
        params => $val,
    };

    my $disp = $self->{_conf_dispatch};

    # Did they specify a config key that exists?
    if ($disp->cmd_exists($key)) {
        my $sub = $disp->get_cmd($key);

        $sub->($self, $conf_args);

        return;
    }

    # If we got this far then it's an unknown config key.
    $irc->msg($who,
        "Sorry, that's not a config key I recognise. See"
        . "https://github.com/grifferz/pah-irc#usage for more info.");
}

# User wants to set a personal pronoun to be used instead of the default
# "their".
#
# We will allow max five characters, a-zA-Z.
sub pronoun {
    my ($self, $args) = @_;

    my $params  = $args->{params};
    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $irc     = $self->_irc;


    # If they didn't specify a pronoun then just tell them what their current
    # pronoun is.
    if (not defined $params or $params =~ /^\s*$/) {
        my $pronoun = $user->pronoun;

        $pronoun = 'their' if (not defined $pronoun);

        $irc->msg($who, sprintf("Your current pronoun is %s.", $pronoun));
        return;
    }

    # Remove trailing/leading white space.
    chomp($params);
    $params =~ s/^\s*//;

    if ($params =~ /^[a-zA-Z]{1,5}$/) {
        $user->pronoun($params);
        $user->update;
        $irc->msg($who, "Your pronoun has been updated to $params.");
        return;
    }

    # It was invalid.
    $irc->msg($who, "Sorry, that doesn't look like a reasonable pronoun. I'll"
       . " accept up to five characters, a-z plus A-Z.");
}

# A user wants to privately list the plays of a completed hand. If the hand is
# not completed then just give an error message.
sub plays {
    my ($self, $args) = @_;

    my $who     = $args->{nick};
    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $channel = undef;

    if (not defined $chan) {
        $channel = $self->guess_channel($who);

        if (defined $channel) {
            $chan = $channel->disp_name;
        }
    } else {
        # They specified a channel, so try to get that one.
        $channel = $self->db_get_channel($chan);

        if (not defined $channel) {
            $chan = undef;
        }
    }

    # By now we either:
    #
    # 1. Guessed the channel and have a channel object in $channel, channel
    #    name in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in
    #    $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so
    #    $channel is undef.
    if (not defined $channel) {
        # Cases 2 or 4.
        if (defined $chan) {
            # They specified the channel but it didn't exist (#4). Probably bot
            # has never been in it.
            debug("%s asked for plays for game in %s but I don't know anything"
                . " about %s", $who, $chan, $chan);
            $irc->msg($who, "Sorry, I have no knowledge of $chan.");
            return;
        }

        # It's case #2.
        debug("%s asked for plays list but I couldn't work out which channel"
            . " they were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested}
            . qq{ in. Try again with "#channel plays".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($who, $chan);
    } else {
        $self->report_plays($game, $who);
    }
}

# A user wants to know about the deck that's in use.
sub deck {
    my ($self, $args) = @_;

    my $who    = $args->{nick};
    my $irc    = $self->_irc;
    my $schema = $self->_schema;

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $channel = undef;

    if (not defined $chan) {
        $channel = $self->guess_channel($who);

        if (defined $channel) {
            $chan = $channel->disp_name;
        }
    } else {
        # They specified a channel, so try to get that one.
        $channel = $self->db_get_channel($chan);

        if (not defined $channel) {
            $chan = undef;
        }
    }

    # By now we either:
    #
    # 1. Guessed the channel and have a channel object in $channel, channel
    #    name in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in
    #    $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so
    #    $channel is undef.
    if (not defined $channel) {
        # Cases 2 or 4.
        if (defined $chan) {
            # They specified the channel but it didn't exist (#4). Probably bot
            # has never been in it.
            debug("%s asked for deck info for game in %s but I don't know"
                . " anything about %s", $who, $chan, $chan);
            $irc->msg($who, "Sorry, I have no knowledge of $chan.");
            return;
        }

        # It's case #2.
        debug("%s asked for deck info but I couldn't work out which channel"
            . " they were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested}
            . qq{ in. Try again with "#channel plays".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->no_such_game($who, $chan);
     } else {
         my $deck = $self->_deck;

         my @packs = $deck->packs;

         # Find the longest name so we can line things up nicely.
         my $longest = reduce { length($a) > length($b) ? $a : $b } @packs;
         my $length = length($longest);

         $irc->msg($who, "Card packs in use (# Black/White):");

         foreach my $p (@packs) {
             $irc->msg($who,
                 sprintf("  %-${length}s (%3u/%3u) %s", $p,
                     $deck->pack_count($p, 'Black'),
                     $deck->pack_count($p, 'White'), $deck->pack_desc($p)));
         }

         my $black_left = $schema->resultset('BCard')->search(
             { game => $game->id }
         )->count;

         my $white_left = $schema->resultset('WCard')->search(
             { game => $game->id }
         )->count;

         $irc->msg($who,
             sprintf("[%s] %u Black, %u White Cards. %u/%u"
                 . " before reshuffle.", $chan, $deck->count('Black'),
                 $deck->count('White'), $black_left, $white_left));
     }
}

1;
