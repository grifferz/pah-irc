=pod
Perpetually Against Humanity, IRC Edition (pah-irc)

Play endless games of Cards Against Humanity on IRC.

https://github.com/grifferz/pah-irc

This code:
    Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

    Artistic license same as Perl.

Get Cards Against Humanity here!
    http://cardsagainsthumanity.com/

    Cards Against Humanity content is distributed under a Creative Commons
    BY-NC-SA 2.0 license. Cards Against Humanity is a trademark of Cards
    Against Humanity LLC.
=cut

package PAH;
our $VERSION = "0.4";

use utf8; # There's some funky literals in here
use Config::Tiny;
use strict;
use warnings;
use Moose;
use MooseX::Getopt;
with 'MooseX::Getopt';
use Try::Tiny;
use List::Util qw/shuffle/;
use POSIX qw/strftime/;
use Storable qw/nstore retrieve/;
use Time::Duration;

use Data::Dumper;

use PAH::IRC;
use PAH::Log;
use PAH::Schema;
use PAH::Deck;

has config_file => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { 'etc/pah-irc.conf' },
);

has _tallyfile => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { 'var/playtally' },
);

has ircname => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { "pah-irc v$VERSION" }
);

has _config => (
    isa     => 'HashRef',
    is      => 'ro',
);

has _irc => (
    isa     => 'PAH::IRC',
    is      => 'ro',
    default => sub { PAH::IRC->new }
);

has _schema => (
    isa => 'PAH::Schema',
    is  => 'ro',
);

has _pub_dispatch => (
    is => 'ro',
);

has _priv_dispatch => (
    is => 'ro',
);

has _whois_queue => (
    is => 'ro',
);

has _deck => (
    is => 'ro',
);

has _plays => (
    is => 'ro',
);

# Stash for lots of "time this last happened" stuff.
has _last => (
    is => 'ro',
);

# Play notification timers for each game.
has _pn_timers => (
    is => 'ro',
);

# Tally of which users have been introduced to the game.
has _intro => (
    is => 'ro',
);

# Tally of who has been poked to perform their game duties.
has _pokes => (
    is => 'ro',
);

sub BUILD {
  my ($self) = @_;

  my $config = Config::Tiny->read($self->config_file)
      or die Config::Tiny->errstr;
  # Only care about the root section for now.
  $self->{_config} = $config->{_};

  if (not defined $self->{_config}->{turnclock}
          or $self->{_config}->{turnclock} !~ /^\d+$/
          or $self->{_config}->{turnclock} <= 0) {
      die "'turnclock' config item must be a positive integer";
  }

  if (defined $self->{_config}->{tallyfile}) {
      $self->{_tallyfile} = $self->{_config}->{tallyfile};
  }

  if (not defined $self->{_config}->{msg_per_sec}) {
      $self->{_config}->{msg_per_sec} = 1;
  }

  if ($self->{_config}->{msg_per_sec} !~ /^[\d\.]+$/
          or $self->{_config}->{msg_per_sec} <= 0) {
      die "'msg_per_sec' config item must be a positive integer";
  }

  if (not defined $self->{_config}->{msg_burst}) {
      $self->{_config}->{msg_burst} = 10;
  }

  if ($self->{_config}->{msg_burst} !~ /^\d+$/
          or $self->{_config}->{msg_burst} <= 0) {
      die "'msg_burst' config item must be a positive integer";
  }

  $self->{_pub_dispatch} = {
      'status'    => {
          sub        => \&do_pub_status,
          privileged => 0,
      },
      'scores'    => {
          sub        => \&do_pub_scores,
          privileged => 0,
      },
      'stats'    => {
          sub        => \&do_pub_scores,
          privileged => 0,
      },
      'start'     => {
          sub        => \&do_pub_start,
          privileged => 1,
      },
      'me'        => {
          sub        => \&do_pub_dealin,
          privileged => 1,
      },
      'me!'       => {
          sub        => \&do_pub_dealin,
          privileged => 1,
      },
      'dealmein'  => {
          sub        => \&do_pub_dealin,
          privileged => 1,
      },
      'resign'    => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
      'dealmeout' => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
      'retire'    => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
      'winner'    => {
          sub        => \&do_pub_winner,
          privileged => 1,
      },
  };

  $self->{_priv_dispatch} = {
      'hand'    => {
          sub        => \&do_priv_hand,
          privileged => 1,
      },
      'list'    => {
          sub        => \&do_priv_hand,
          privileged => 1,
      },
      'black'   => {
          sub        => \&do_priv_black,
          privileged => 0,
      },
      'play'    => {
          sub        => \&do_priv_play,
          privileged => 1,
      },
      'pronoun' => {
          sub        => \&do_priv_pronoun,
          privileged => 1,
      },
      'status'  => {
          sub        => \&do_priv_status,
          privileged => 0,
      },
      'scores'   => {
          sub        => \&do_priv_scores,
          privileged => 0,
      },
      'stats'    => {
          sub        => \&do_priv_scores,
          privileged => 0,
      },
  };

  $self->{_whois_queue} = {};

  my $default_deck = 'cah_uk';

  $self->{_deck} = PAH::Deck->load($default_deck);

  my $deck = $self->{_deck}->{$default_deck};

  debug("Loaded deck: %s", $deck->{Description});
  debug("Deck has %u Black Cards, %u White Cards",
      scalar @{ $deck->{Black} }, scalar @{ $deck->{White} });

  $self->{_last}      = {};
  $self->{_pn_timers} = {};
  $self->{_intro}     = {};
  $self->{_pokes}     = {};
}

# The "main"
sub start {
    my ($self) = @_;

    $self->db_connect;
    $self->{_plays} = $self->load_tallyfile;

    try {
        $self->connect;
        AnyEvent->condvar->recv;
    } catch {
        # Just the first line, Moose can spew rather long errors.
        $self->_irc->disconnect("Died: " . (/^(.*)$/m)[0]);
        warn $_;
    };
}

sub db_connect {
    my ($self) = @_;

    my $c = $self->_config;

    my $dbfile = $c->{dbfile};

    if (not defined $dbfile) {
        die "Config item 'dbfile' must be specified\n";
    }

    if (! -w $dbfile) {
        die "SQLite database $dbfile isn't writable\n";
    }

    $self->{_schema} = PAH::Schema->connect("dbi:SQLite:$dbfile", '', '',
        { sqlite_unicode => 1 });
}

sub shutdown {
  my ($self) = @_;

  $self->_irc->disconnect("Shutdown");
}

sub handle_sighup {
  my ($self) = @_;
}

sub connect {
    my ($self) = @_;
    my $c = $self->_config;

    $self->_irc->connect($self,
        $c->{target_server}, $c->{target_port},
        {
            nick      => $c->{nick},
            nick_pass => $c->{nick_pass},
            user      => $c->{username},
            real      => $self->ircname,
            password  => $self->{target_pass},
        }
    );
}

sub joined {
    my($self, $chan) = @_;

    my $name   = lc($chan);
    my $schema = $self->_schema;

    debug("Joined %s", $chan);

    # Is there a game for this channel already in existence?
    my $channel = $schema->resultset('Channel')->find({ name => $name });

    return unless (defined $channel);

    my $game = $channel->rel_game;

    return unless (defined $game);

    debug("%s appears to have a game in existence…", $chan);

    if (0 == $game->status) {
        debug("…and it's currently paused so I'm going to activate it");

        my $num_players = scalar $game->rel_active_usergames;

        if ($num_players < 4) {
            $game->status(1); # Waiting for players.
            debug("Game for %s only had %u player(s) so I set it as"
               . " waiting", $chan, $num_players);
        } else {
            $game->status(2); # We're on.
            $game->activity_time(time());
            debug("Game for %s has enough players so it's now active",
                $chan);
        }

        $game->update;
    } else {
        my $status_txt;

        if (1 == $game->status) {
            $status_txt = "waiting for players";
        } elsif (2 == $game->status) {
            $status_txt = "running";
        } else {
            $status_txt = "in an invalid state";
        }

        debug("…but it's currently %s, so I won't do anything about that",
            $status_txt);
    }
}

# A user joined a channle that we're in. Decide about whether we're going to
# introduce them to the game, and then do so.
#
# Arguments:
#
# - The channel name as a scalar.
#
# - The nick name as a scalar.
#
# Returns:
#
# Nothing.
sub user_joined {
    my($self, $chan, $nick) = @_;

    my $schema  = $self->_schema;
    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();

    $chan = lc($chan);

    # Need the original case for disp_nick.
    my $lc_nick = lc($nick);

    debug("* %s joined %s", $nick, $chan);

    # Did we already introduce this user?
    if (defined $self->_intro->{$lc_nick}) {
        # Yes, so do nothing.
        return;
    }

    # Is there a game for this channel already in existence?
    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        debug("Somehow got a join event for a channel %s we have no knowledge of",
            $chan);
        return;
    }

    my $game = $channel->rel_game;

    if (not defined $game or 0 == $game->status) {
        # Game has never existed, so keep quiet.
        debug("Not introducing %s to game at %s because it isn't running", $nick,
            $chan);
        return;
    }

    # A game exists (but could be paused), someone has joined, they haven't
    # been introduced before…

    # …but are they already playing?
    my $ug = $self->db_get_nick_in_game($nick, $game);

    if (defined $ug) {
        # Must know about the game even if they aren't currently active, so
        # don't bother.
        return;
    }

    # Introduce!
    debug("Introducing %s to the game in %s", $nick, $chan);
    $self->_intro->{$lc_nick} = time();

    if (2 == $game->status) {
        $irc->msg($nick,
            sprintf(qq{Hi! I'm currently running a game of Perpetually Against}
                . qq{ Humanity in %s. Are you interested in playing?}, $chan));
    } else {
        $irc->msg($nick,
            sprintf(qq{Hi! I'm currently gathering players for a game of}
                . qq{ Perpetually Against Humanity in %s. Are you interested in}
                . qq{ joining?}, $chan));
    }

    $irc->msg($nick,
        qq{If so then just type "$my_nick: deal me in" in the channel.});
    $irc->msg($nick,
        qq{See https://github.com/grifferz/pah-irc for more info. I won't bother}
       . qq{ you again if you're not interested!});

}

# Mark a channel as no longer welcoming, for whatever reason. Usually because
# we just got kicked out of it.
sub mark_unwelcome {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    # Downcase channel names for storage.
    my $name = lc($chan);

    my $channel = $schema->resultset('Channel')->find({ name => $name });

    if (defined $channel) {
        $channel->welcome(0);
        $channel->update;
        debug("Marked %s as unwelcoming", $chan);

        # Now mark any associated game as paused.
        if (defined $channel->rel_game) {
            $channel->rel_game->status(0); # Paused.
            $channel->rel_game->activity_time(time());
            $channel->rel_game->update;
            debug("Game for %s is now paused", $chan);
        }
    } else {
        debug("Tried to mark %s as unwelcoming but couldn't find it in the"
           . " database!", $name);
   }
}

# Mark a channel as welcome, creating it in the database in the process if
# necessaary.
sub create_welcome {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    # Downcase channel names for storage.
    my $name = lc($chan);

    my $channel = $schema->resultset('Channel')->update_or_new(
        {
            name      => $name,
            disp_name => $chan,
            welcome   => 1,
        }
    );

    if ($channel->in_storage) {
        # The channel was already there and was only updated.
        debug("I'm now welcome in %s", $chan);
    } else {
        # This is a new row and needs actually populating.
        $channel->insert;
        debug("I'm now welcome in new channel %s", $chan);
    }
}

# Try to join all the channels from our database that we know are welcoming
# towards our presence.
sub join_welcoming_channels {
    my ($self) = @_;

    my $schema = $self->_schema;

    my $welcoming_chans = $schema->resultset('Channel')->search(
        {
            welcome => 1,
        }
    );

    for my $channel ($welcoming_chans->all) {
        debug("Looks like I'm welcome in %s; joining…", $channel->disp_name);
        $self->_irc->send_srv(JOIN => $channel->name);
    }
}

# Deal with a possible command directed at us in private message.
sub process_priv_command {
    my ($self, $sender, $cmd) = @_;

    # Downcase everything, even the command, as there currently aren't any
    # private commands that could use mixed case.
    $sender = lc($sender);
    $cmd    = lc($cmd);

    my $chan = undef;
    my $rest = undef;

    my $disp = $self->_priv_dispatch;

    # Is it just 1 or two digits? If so then modify it to be the equivalent
    # play command.
    if ($cmd =~ /^(\d+)\s*(\d+)?$/) {
        $cmd = "play $1";
        $cmd .= " $2" if (defined $2);
    }

    # Does the command have a channel specified?
    #
    # Private commands look like this:
    #
    # some_command
    # some_command and some arguments
    # #foo some_command
    # #foo some_command and some arguments
    #
    #
    # The first asks to perform "some_command" in the single game that the user
    # is active in. This will be an error if the user is active in multiple
    # games.
    #
    # The second specifies that the command relates to the game being carried
    # out in channel #foo, which removes the ambiguity.
    if ($cmd =~ /^([#\&]\S+)\s+(\S+)(.*)?$/) {
        $chan = $1;
        $cmd  = $2;
        $rest = $3;
    } elsif ($cmd =~ /^\s*(\S+)(.*)?$/) {
        $cmd  = $1;
        $rest = $2;
    }

    # Strip off any leading/trailing whitespace.
    if (defined $rest) {
        $rest =~ s/^\s+//;
        $rest =~ s/\s+$//;
    };

    my $args = {
        nick   => $sender,
        chan   => $chan,
        public => 0,
        params => $rest,
    };

    if (exists $disp->{$cmd}) {
        if (0 == $disp->{$cmd}->{privileged}) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $disp->{$cmd}->{sub}->($self, $args);
        } else {
            # This command requires the user to be identified to a registered
            # nickname. We'll ensure this by:
            #
            # 1. Storing the details onto a queue.
            # 2. Issuing a WHOIS for the user.
            # 3. Checking the queue when we receive a WHOIS reply, later.
            # 4. Executing the callback at that time if appropriate.
            queue_whois_callback($self,
                {
                    target   => $args->{nick},
                    callback => $disp->{$cmd},
                    cb_args  => $args,
                }
            );
        }
    } else {
        do_unknown($self, $args);
    }
}

# Deal with a public command directed at us in a channel.
sub process_chan_command {
    my ($self, $sender, $chan, $cmd) = @_;

    # Downcase everything, even the command, as there currently aren't any
    # public commands that could use mixed case.
    $chan   = lc($chan);
    $cmd    = lc($cmd);

    my $rest = undef;

    if ($cmd =~ /^(\d+)$/) {
        # All they said was a single digit, so treat it as picking a winner.
        $rest = $1;
        $cmd  = "winner";
    } elsif ($cmd eq 'deal me in') {
        $cmd = 'dealmein';
    } elsif ($cmd eq 'deal me out') {
       $cmd = 'dealmeout';
    } elsif ($cmd =~ /^\s*(\S+)(.*)?$/) {
        $cmd  = $1;
        $rest = $2;

        # Strip off any leading/trailing whitespace.
        if (defined $rest) {
            $rest =~ s/^\s+//;
            $rest =~ s/\s+$//;
        }
    }

    my $disp = $self->_pub_dispatch;

    my $args = {
        nick   => $sender,
        chan   => $chan,
        public => 1,
        params => $rest,
    };

    if (exists $disp->{$cmd}) {
        if (0 == $disp->{$cmd}->{privileged}) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $disp->{$cmd}->{sub}->($self, $args);
        } else {
            # This command requires the user to be identified to a registered
            # nickname. We'll ensure this by:
            #
            # 1. Storing the details onto a queue.
            # 2. Issuing a WHOIS for the user.
            # 3. Checking the queue when we receive a WHOIS reply, later.
            # 4. Executing the callback at that time if appropriate.
            queue_whois_callback($self,
                {
                    target   => $args->{nick},
                    channel  => $chan,
                    callback => $disp->{$cmd},
                    cb_args  => $args,
                }
            );
        }
    } else {
        do_unknown($self, $args);
    }
}

# Issue a 'whois' command with a callback function that will be executed
# provided that the results of the whois are as expected. This is going to
# check for the services account info being present.
sub queue_whois_callback {
    my ($self, $cb_info) = @_;

    my $irc         = $self->_irc;
    my $whois_queue = $self->_whois_queue;
    my $time        = time();
    my $target      = lc($cb_info->{target});

    my $queue_entry = {
        info      => $cb_info,
        timestamp => $time,
    };

    # The WHOIS queue is a hash of lists keyed off the nickname.
    # Initialise the queue for the target nickname to the empty list, if it
    # doesn't already exist.
    $whois_queue->{$target} = [] if (not exists $whois_queue->{$target});

    my $queue = $whois_queue->{$target};

    debug("Queueing a WHOIS callback against %s", $target);

    push(@{ $queue }, $queue_entry);

    $irc->send_srv(WHOIS => $target);
}

sub execute_whois_callback {
    my ($self, $item) = @_;

    my $callback = $item->{info}->{callback};
    my $cb_args  = $item->{info}->{cb_args};

    # Execute it.
    $callback->{sub}->($self, $cb_args);
}

sub denied_whois_callback {
    my ($self, $item) = @_;

    my $callback = $item->{info}->{callback};
    my $cb_args  = $item->{info}->{cb_args};
    my $chan     = $item->{info}->{channel};
    my $nick     = $item->{info}->{target};

    if (defined $chan) {
        # Callback was related to a channel.
        $self->_irc->msg($chan,
            "$nick: Sorry, you need to be identified to a registered nickname"
           . " to do that. Try again after identifying to Services.");
    } else {
        $self->_irc->msg($nick,
            "Sorry, you need to be identified to a registered nickname to do"
           . " that. Try again after identifying to Services.");
    }
}

# Didn't match any known command.
sub do_unknown {
    my ($self, $args) = @_;

    my $chan = $args->{chan};
    my $who  = $args->{nick};

    my $target;

    # Errors to go to the channel if the command came from the channel,
    # otherwise in private to the sender.
    if (1 == $args->{public}) {
        $target = $chan;
    } else {
        $target = $who;
    }

    if (defined $chan) {
        $self->_irc->msg($target,
            "$who: Sorry, that's not a command I recognise. See"
            . " https://github.com/grifferz/pah-irc#usage for more info.");
    } else {
        $self->_irc->msg($target,
            "Sorry, that's not a command I recognise. See"
           . " https://github.com/grifferz/pah-irc#usage for more info.");
    }
}

sub do_priv_scores {
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
    # 1. Guessed the channel and have a channel object in $channel, channel name
    #    in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so $channel
    #    is undef.
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
        debug("%s asked for game scores but I couldn't work out which channel they"
           . " were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested in.}
           . qq{ Try again with "#channel scores".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $irc->msg($who,
            "There's no game of Perpetually Against Humanity in $chan.");
        $irc->msg($who,
            "Want to start one? Anyone with a registered nickname can do so.");
        $irc->msg($who,
            qq{Just type "$my_nick: start" in $chan and find at least 3}
           . qq{ friends.});
        return;
    }

    $self->report_game_scores($game, $who);
}

# Find the best channel for a nickname.
#
# If the nickname is only in one channel/game then return that one.
#
# If they're in multiple channels but only one of them has an active game then
# return that one.
#
# Otherwise returns undef.
#
# Arguments:
#
# - Nickname as scalar string.
#
# Returns:
#
# Game Schema object or undef.
sub guess_channel {
    my ($self, $nick) = @_;

    my $irc = $self->_irc;
    my $lc_who = lc($nick);

    # Hash reference whose keys are the channels the bot is in, and the
    # values are a hash reference of nick names in the channel.
    my $chan_list = $irc->channel_list();

    my @nick_is_in;

    foreach my $c (keys %{ $chan_list }) {
        # Can't just do a key lookup because the nick hash contains mixed
        # case nicks.
        foreach my $n (keys %{ $chan_list->{$c} }) {
            if ($lc_who eq lc($n)) {
                push(@nick_is_in, $c);
                last;
            }
        }
    }

    my @gamechans_nick_is_in;

    foreach my $c (@nick_is_in) {
        my $dbchan = $self->db_get_channel($c);

        if (defined $dbchan and defined $dbchan->rel_game) {
            push(@gamechans_nick_is_in, $dbchan);
        }
    }

    # So @gamechans_nick_is_in is now an array of Channel objects for
    # channels that this nick is in, where games are being played.
    #
    # Of these channels, which ones have an active game in?
    my @active_gamechans_nick_is_in = grep {
        2 == $_->rel_game->status } @gamechans_nick_is_in;

    if (1 == scalar @active_gamechans_nick_is_in) {
        # They're in just one channel that has an active game, so assume
        # they meant that one.
        return $active_gamechans_nick_is_in[0];
    }

    # They're in multiple channels that have active games. How many of
    # them are they actually active in?
    my @they_are_active_in;

    foreach my $c (@active_gamechans_nick_is_in) {
        my $ug = $self->db_get_nick_in_game($lc_who, $c->rel_game);
        push(@they_are_active_in, $c) if (defined $ug);
    }

    if (1 == scalar @they_are_active_in) {
        # Cool, even though they're watching multiple games they are
        # only active in one of them, so assume they emant that one.
        return $they_are_active_in[0];
    }

    # They're active in multiple games and are in the channels
    # watching more than one, so we have no idea which one they
    # meant. They're going to have to specify.
    return undef;
}

sub do_priv_status {
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
    # 1. Guessed the channel and have a channel object in $channel, channel name
    #    in $chan.
    # 2. Couldn't guess the channel and have an undef $channel object, undef
    #    $chan.
    # 3. Have a specified a channel in $chan, and we found the object in $channel.
    # 4. Have a specified a channel in $chan but we couldn't find it, so $channel
    #    is undef.
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
        debug("%s asked for game status but I couldn't work out which channel they"
           . " were interested in", $who);
        $irc->msg($who,
            qq{Sorry, I can't work out which channel's game you're interested in.}
           . qq{ Try again with "#channel status".});
        return;
    }

    # Must be cases 1 or 3.
    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $irc->msg($who,
            "There's no game of Perpetually Against Humanity in $chan.");
        $irc->msg($who,
            "Want to start one? Anyone with a registered nickname can do so.");
        $irc->msg($who,
            qq{Just type "$my_nick: start" in $chan and find at least 3}
           . qq{ friends.});
    } elsif (2 == $game->status) {
        $self->report_game_status($game, $who);
    } elsif (1 == $game->status) {
        my $num_players = scalar $game->rel_active_usergames;

        # Game is still gathering players. Give different response depending on
        # whether they are already in it or not.
        my $ug = $self->db_get_nick_in_game($who, $game);

        if (defined $ug) {
            $irc->msg($who,
                sprintf("A game exists in %s but we only have %u player%s "
                    . "(%s). Find me %u more and we're on.", $chan,
                    $num_players, 1 == $num_players ? '' : 's',
                    1 == $num_players ? 'you' : 'including you',
                    4 - $num_players));
        } else {
            $irc->msg($who,
                sprintf("A game exists in %s but we only have %u player%s."
                   . " Find me %umore and we're on.", $chan, $num_players,
                   1 == $num_players ? '' : 's', 4 - $num_players));
        }
    } elsif (0 == $game->status) {
        $irc->msg($who,
            "The game in $chan is paused but I don't know why!"
            . " Report this!");
    } else {
        debug("Game for %s has an unexpected status (%u)", $chan, $game->status);
        $irc->msg($who,
            "I'm confused about the state of the game in $chan, sorry!"
            . " Report this!");
    }
}

# Work out the top 3 scorers for a given game, taking ties into account.
#
# Arguments:
#
# - The Game schema object.
#
# Returns:
#
# An array of the top 3 winners taking ties into account, but not including any
# zero scorers.
sub top3_scorers {
    my ($self, $game) = @_;

    my $schema = $self->_schema;

    my $inner = $schema->resultset('UserGame')->search(
        {
            game => $game->id,
            wins => { '>' => 0 },
        },
        {
            columns  => [ qw/wins/ ],
            distinct => 1,
            rows     => 3,
            order_by => 'wins DESC',
        }
    );

    my @top3 = $schema->resultset('UserGame')->search(
        {
            game => $game->id,
            wins => { -in => $inner->get_column("wins")->as_query },
        },
        {
            prefetch => 'rel_user',
            order_by => 'wins DESC',
        },
    );

    return @top3;
}

sub do_pub_scores {
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
                sprintf("$who: Sorry, I'm ignoring your scores command because"
                   . " I did one just %u secs ago.", ($now - $last_scores)));
            return;
        }

        # Record timestamp of when we did this.
        $self->_last->{$game->id}->{scores} = $now;
    }

    if (not defined $game) {
        # There's never been a game in this channel.
        my $my_nick = $irc->nick();

        $irc->msg($chan,
            "$who: There's no game of Perpetually Against Humanity in here.");
        $irc->msg($chan,
            "Want to start one? Anyone with a registered nickname can do so.");
        $irc->msg($chan,
            qq{Just type "$my_nick: start" and find at least 3 friends.});
        return;
    }

    # Game is either running or gathering players.
    $self->report_game_scores($game, $chan);
}

# Report the scores of a game to either a nick or a channel.
#
# Arguments:
#
# - Game Schema object.
#
# - The target of the output (nick or channel) as a scalar string.
#
# Returns:
#
# Nothing.
sub report_game_scores {
    my ($self, $game, $target) = @_;

    my $irc  = $self->_irc;
    my $chan = $game->rel_channel->name;

    my @active_usergames = $game->rel_active_usergames;

    # Sort UserGames by score.
    @active_usergames = sort {
        $b->wins <=> $a->wins
    } @active_usergames;

    my $winstring = join(' ',
        map {
            my $user = $_->rel_user;
            my $nick = $user->disp_nick;

            $nick = $user->nick if (not defined $nick);

            $nick . ($_->wins > 0 ? '(' . $_->wins . ')' : '');
        } @active_usergames);

    # If the target is a nickname then we need to prepend the channel so they
    # know what we're talking about.
    my $is_nick = 1;

    if ($target =~ /^[#\&]/) {
        $is_nick = 0;
        $chan    = $target;
    }

    $irc->msg($target,
        sprintf("%sActive Players: %s", $is_nick ? "[$chan] " : '',
            $winstring));

    my @top3 = $self->top3_scorers($game);

    # Might not be any non-zero scores.
    if (scalar @top3) {
        $winstring = join(' ',
            map {
                my $user = $_->rel_user;
                my $nick = $user->disp_nick;

                $nick = $user->nick if (not defined $nick);

                $nick . ($_->wins > 0 ? '(' . $_->wins . ')' : '');
            } @top3);
        $irc->msg($target,
            sprintf("%sTop 3 all time: %s", $is_nick ? "[$chan] " : '',
                $winstring));
    } else {
        $irc->msg($target,
            sprintf("%sTop 3 all time: No wins yet!",
                $is_nick ? "[$chan] " : ''));
    }
}

sub do_pub_status {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $irc     = $self->_irc;
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
            and defined $self->_last->{$game->id}->{status}) {
        my $last_status = $self->_last->{$game->id}->{status};

        if (($now - $last_status) <= 120) {
            # Last time we did status in this channel was 120 seconds ago or less.
            debug("%s tried to display status for %s but it was already done %u"
               . " secs ago; ignoring", $who, $chan, ($now - $last_status));
            $irc->msg($chan,
                sprintf("$who: Sorry, I'm ignoring your status command in"
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
        $irc->msg($chan,
            "$who: There's no game of Perpetually Against Humanity in here.");
        $irc->msg($chan,
            "Want to start one? Anyone with a registered nickname can do so.");
        $irc->msg($chan,
            qq{Just type "$my_nick: start" and find at least 3 friends.});
    } elsif (2 == $game->status) {
        $self->report_game_status($game, $chan);
    } elsif (1 == $game->status) {
        my $num_players = scalar $game->rel_active_usergames;

        # Game is still gathering players. Give different response depending on
        # whether they are already in it or not.
        my $ug = $self->db_get_nick_in_game($who, $game);

        if (defined $ug) {
            $irc->msg($chan,
                sprintf("%s: A game exists but we only have %u player%s"
                   . " (%s). Find me %u more and we're on.", $who, $num_players,
                   1 == $num_players ? '' : 's',
                   1 == $num_players ? 'you' : 'including you', 4 - $num_players));
            $irc->msg($chan,
                qq{Any takers? Just type "$my_nick: me" and you're in.});
        } else {
            $irc->msg($chan,
                sprintf("%s: A game exists but we only have %u player%s. Find"
                   . " me %u more and we're on.", $who, $num_players,
                   1 == $num_players ? '' : 's', 4 - $num_players));
            $irc->msg($chan,
                qq{$who: How about you? Just type "$my_nick: me" and you're in.});
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

# Report the status of an active game to either a nick or a channel.
#
# Arguments:
#
# - Game Schema object.
#
# - The target of the output (nick or channel) as a scalar string.
#
# Returns:
#
# Nothing.
sub report_game_status {
    my ($self, $game, $target) = @_;

    my $irc  = $self->_irc;
    my $chan = $game->rel_channel->name;
    my $tsar = $game->rel_tsar_usergame;

    my $waitstring;

    my $tsar_nick = $tsar->rel_user->disp_nick;

    $tsar_nick = $tsar->rel_user->nick if (not defined $tsar_nick);

    if ($self->hand_is_complete($game)) {
        # Waiting on Card Tsar.
        $waitstring = sprintf("Waiting on %s to pick the winning play.",
            $tsar_nick);
    } else {
        my @to_play     = $self->waiting_on($game);
        my $num_waiting = scalar @to_play;

        if ($num_waiting == 1) {
            # Only one person, so shame them.
            my $user    = $to_play[0]->rel_user;
            my $pronoun = $user->pronoun;

            $pronoun = 'their' if (not defined $pronoun);

            my $nick = $user->disp_nick;

            $nick = $user->nick if (not defined $nick);

            $waitstring = sprintf("Waiting on %s to make %s play.", $nick,
                $pronoun);
        } else {
            # Multiple people so just number them.
            $waitstring = sprintf("Waiting on %u %s to make their play%s.",
                $num_waiting, $num_waiting == 1 ? 'person' : 'people',
                $num_waiting == 1 ? '' : 's');
        }
    }

    my $start_time    = $game->round_time;
    my $activity_time = $game->activity_time;

    # round_time is a new column and may be unset (0); if so then use
    # activity_time.
    $start_time       = $activity_time if (0 == $start_time);

    my $now           = time();
    my $started_ago   = $now - $start_time;
    my $punishment_in = $activity_time + $self->_config->{turnclock} - $now;

    # If the target is a nickname then we need to prepend the channel so they
    # know what we're talking about.
    my $is_nick = 1;

    if ($target =~ /^[#\&]/) {
        $is_nick = 0;
        $chan    = $target;
    }

    $irc->msg($target,
        sprintf("%s%s Round started about %s ago. Idle punishment in about"
           . " %s.", $is_nick ? "[$chan] " : '', $waitstring,
           concise(duration($started_ago, 2)),
           concise(duration($punishment_in, 2))));

    $irc->msg($target,
        sprintf("%sThe Card Tsar is %s; current Black Card:",
            $is_nick ? "[$chan] " : '', $tsar_nick));

    $self->notify_bcard($target, $game);
}

# User wants to start a new game in a channel.
sub do_pub_start {
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
            my $count = scalar ($game->rel_active_usergames);

            $irc->msg($chan,
                "$who: Sorry, there's already a game here but we only have"
               . " $count of minimum 4 players. Does anyone else want to"
               . " play?");
            $irc->msg($chan, qq{Type "$my_nick: me" if you'd like to!});
        } elsif (2 == $status) {
            $irc->msg($chan, "$who: Sorry, there's already a game running here!");
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

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    # In the absence of being able to know who pooped last, the starting user
    # will be the first Card Tsar.
    my $usergame = $schema->resultset('UserGame')->create(
        {
            user          => $user->id,
            game          => $game->id,
            is_tsar       => 1,
            tsarcount     => 1,
            active        => 1,
            activity_time => time(),
        }
    );

    # Now tell 'em.
    $irc->msg($chan,
        "$who: You're on! We have a game of Perpetually Against Humanity up in"
       . " here. 4 players minimum are required. Who else wants to play?");
    $irc->msg($chan,
        qq{Say "$my_nick: me" if you'd like to!});
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
sub do_pub_dealin {
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

    # Is the game's current hand complete (waiting on Card Tsar)? If so then no
    # new players can join, because then everyone would know who the extra play
    # was from. Tell them to try again after the current hand.
    if (2 == $game->status and $self->hand_is_complete($game)) {
        # TODO: Maybe keep track that they wanted to play, and deal them in as
        # soon as the current hand finishes?
        debug("%s can't join game at %s because the hand is complete", $who, $chan);
        $irc->msg($chan,
            sprintf("%s: Sorry, this hand is complete and we're waiting on %s"
               . " to pick the winner. Please try again later.", $who,
               $game->rel_tsar_usergame->rel_user->nick));
        return;
    }

    # Maximum 20 players in a game.
    my $num_players = scalar @active_usergames;

    if ($num_players >= 20) {
        debug("%s can't join game at %s because there's already %s players", $who,
            $chan, $num_players);
        $irc->msg($chan,
            "$who: Sorry, there's already $num_players players in this game and"
           . " that's the maximum. Try again once someone has resigned!");
        return;
    }

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    my $usergame = $schema->resultset('UserGame')->update_or_create(
        {
            user          => $user->id,
            game          => $game->id,
            active        => 1,
            activity_time => time(),
        }
    );

    # Update player activity timer.
    $usergame->activity_time(time());
    $usergame->update;

    debug("%s was added to game at %s", $who, $chan);
    $irc->msg($chan, "$who: Nice! You're in!");

    # Does the game have enough players to start yet?
    $num_players = scalar $game->rel_active_usergames;

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

        $irc->msg($chan, "$prefix Give me a minute or two to tell everyone their"
               . " hands without flooding myself off, please.");

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
        debug("Game at %s still requires %u more players", $chan, 4 - $num_players);
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

# A user wants to resign from the game. If they are the current round's Card
# Tsar then they aren't allowed to resign. Otherwise, their White Cards
# (including any that were already played in this round) are discarded and they
# are removed from the running game.
#
# If this brings the number of players below 4 then the game will be paused.
#
# The player can rejoin the game at a later time.
sub do_pub_resign {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();
    my $irc     = $self->_irc;

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel. That's"
           . " weird and shouldn't happen. Report this!");
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
        debug("%s tried to resign from game in %s but they weren't active", $who,
            $chan);
        $irc->msg($chan, "$who: You're not playing!");
        return;
    }

    $irc->msg($chan, "$who: Okay, you've been dealt out of the game.");
    $irc->msg($chan,
        qq{$who: If you want to join in again later then type}
        . qq{ "$my_nick: deal me in"});

    $self->resign($usergame);
}

sub resign {
    my ($self, $ug) = @_;

    my $user    = $ug->rel_user;
    my $game    = $ug->rel_game;
    my $channel = $game->rel_channel;
    my $chan    = $channel->disp_name;
    my $who     = $user->disp_nick;
    my $irc     = $self->_irc;

    $who = $user->nick if (not defined $who);

    # Are they the Card Tsar?
    if (1 == $ug->is_tsar) {
        debug("%s was Tsar for %s", $who, $chan);

        if (2 == $game->status and $self->hand_is_complete($game)) {
            debug("Played cards in %s have been seen so must be discarded", $chan);
            $self->cleanup_plays($game);
        } else {
            # Just delete everyone's plays.
            delete $self->_plays->{$game->id};
            $self->write_tallyfile;
        }

        # And discard their hand of White Cards.
        $self->discard_hand($ug);

        # Mark them as inactive.
        $ug->activity_time(time());
        $ug->active(0);
        $ug->update;

        # Give the other players any new cards they need.
        $self->topup_hands($game);

        # Elect the next Tsar.
        $self->pick_new_tsar(undef, undef, undef, $game);
        $self->clear_pokes($game);
    } else {
        # Trash any plays this user may have made.
        $self->delete_plays($ug);

        # And discard their hand of White Cards.
        $self->discard_hand($ug);

        # Mark them as inactive.
        $ug->active(0);
        $ug->update;
    }

    # Has this taken the number of players too low for the game to continue?
    my $player_count = scalar $game->rel_active_usergames;

    if ($player_count < 4) {
        my $my_nick = $irc->nick();

        debug("Resignation of %s in %s has brought the game down to %u player%s",
            $who, $chan, $player_count, 1 == $player_count ? '' : 's');
        $game->status(1);
        $game->update;

        $irc->msg($chan,
            sprintf("That's taken us down to %u player%s. Game paused until we get"
                . " back up to 4.", $player_count, 1 == $player_count ? '' : 's'));
        $irc->msg($chan,
            qq{Would anyone else would like to play? If so type "$my_nick: me"});
    }

    # Has this actually completed the hand (i.e. we were waiting on the user who
    # just resigned)?
    if (2 == $game->status and $self->hand_is_complete($game)) {
        debug("Resignation of %s in %s has completed the hand", $who, $chan);
        $irc->msg($chan,
            "Now that $who was dealt out, all the plays are in."
           . " No more changes!");
        $self->prep_plays($game);
        $self->list_plays($game);
    }
}

# Someone is asking for their current hand (of White Cards) to be displayed.
#
# First assume that they are only in one game so the channel will be implicit.
# If this proves to not be the case then ask them to try again with the channel
# specified.
sub do_priv_hand {
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

        # Sort them by "wcardidx".
        @cards = sort { $a->wcardidx <=> $b->wcardidx } @cards;

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

# Get the user row from the database that corresponds to the user nick as
# a string.
#
# If there is no such user in the database then:
#
# - Create it.
# - Populate the disp_nick field.
#
# If there is such a row already then check if the disp_nick field needs to be
# populated.
#
# Arguments:
#
# - user nick
#
# Returns:
#
# PAH::Schema::Result::User object
sub db_get_user {
    my ($self, $nick) = @_;

    my $schema = $self->_schema;

    my $user = $schema->resultset('User')->find_or_new(
        { 'nick' => lc($nick) },
    );

    if (not $user->in_storage) {
        # This user was just created, so set its disp_nick now and insert it.
        $user->disp_nick($nick);
        $user->insert;
    }

    # Set the disp_nick to the same as nick if it is null (old, pre-existing
    # row, before we started storing disp_nick).
    if (not defined $user->disp_nick) {
        debug("Populating %s's null disp_nick as %s", lc($nick), $nick);
        $user->disp_nick($nick);
        $user->update;
    }

    return $user;
}


# Get the channel row from the database that corresponds to the channel name as
# a string.
#
# Arguments:
#
# - channel name
#
# Returns:
#
# PAH::Schema::Result::Channel object, or undef.
sub db_get_channel {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('Channel')->find(
        { 'name' => $chan },
    );
}

# Create a card deck of the correct color in the database, unique to a specific
# game, referencing indices into our arrays of cards.
#
# The indices of the cards will be inserted in random order. Therefore we can
# iterate through a random deck by selecting increasing row ID numbers.
#
# Our template decks are:
#  $self->_deck->{deckname}->{Black}
#  $self->_deck->{deckname}->{White}
#
# Arguments:
#
# - Game Schema object
#
# - The color of the deck to populate as a scalar string. Should be either:
#   - Black
#   - White
#
# Returns:
#
# Nothing.
sub db_populate_cards {
    my ($self, $game, $color) = @_;

    if ($color ne 'Black' and $color ne 'White') {
        die "color must be either 'Black' or 'White'";
    }

    my $schema   = $self->_schema;
    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};

    my $num_cards = scalar @{ $deck->{$color} };

    debug("Shuffling deck of %u %s Cards from the %s set, for game at %s",
        $num_cards, $color, $deckname, $game->rel_channel->disp_name);

    my @card_indices = shuffle (0 .. ($num_cards - 1));

    if ($color eq 'White') {
        # Don't try to insert White Cards that are already in someone's hand.

        # Get all the players and prefetch their whole hand.
        my @players = $schema->resultset('UserGame')->search(
            { game => $game->id },
            { prefetch => 'rel_usergamehands' }
        );

        my @hand_card_indices;

        # Make an array of card indices of the cards in every player's hands.
        foreach my $ug (@players) {
=pod
            debug("Dropping %u cards from %s hand", scalar $ug->rel_usergamehands,
                $ug->rel_user->nick);

            foreach my $ugh ($ug->rel_usergamehands) {
                debug("  Dropped: %s", $deck->{White}->[$ugh->wcardidx]);
            }
=cut
            push(@hand_card_indices, map { $_->wcardidx } $ug->rel_usergamehands);
        }

        # Remove the hand cards from the deck's cards.
        my %seen;
        @seen{@card_indices} = ( );
        delete @seen { @hand_card_indices };

        debug("Dropped %u cards which are currently in %s players' hands",
            scalar @hand_card_indices, $game->rel_channel->disp_name);
        @card_indices = keys %seen;
    }

    my @cards = map { { game => $game->id, cardidx => $_ } } @card_indices;

    my $table = ($color eq 'Black'? 'BCard' : 'WCard');

    $schema->resultset($table)->populate(\@cards);
}

# A game has just started so give a brief private introduction to each player.
#
# Arguments:
#
# - Game Schema object
#
# Returns:
#
# Nothing.
sub brief_players {
    my ($self, $game) = @_;

    my $chan      = $game->rel_channel->disp_name;
    my $irc       = $self->_irc;
    my $my_nick   = $irc->nick();
    my $turnclock = $self->_config->{turnclock};

    my @active_usergames = $game->rel_active_usergames;

    foreach my $ug (@active_usergames) {
        my $who = $ug->rel_user->nick;

        $irc->msg($who,
            "Hi! The game's about to start. You may find it easier to keep this"
           . " window open for sending me game commands.");
        $irc->msg($who,
            sprintf("Turns in this game can take around %s (mostly done within"
               . " %s though), so there's no need to rush.",
               duration($turnclock * 2), duration($turnclock)));
        $irc->msg($who,
            qq{If you need to stop playing though, please type "$my_nick: resign"}
           . qq{ in $chan so the others aren't kept waiting.});
    }
}

# A single player needs their hand topping up to 10 White Cards.
#
# Arguments:
#
# - UserGame Schema object.
#
# Returns:
#
# - Nothing.
sub topup_hand {
    my ($self, $ug) = @_;

    my $schema     = $self->_schema;
    my $user       = $ug->rel_user;
    my $game       = $ug->rel_game;
    my $num_wcards = scalar $ug->rel_usergamehands;
    my $channel    = $game->rel_channel;

    debug("%s currently has %u White Cards in %s game",
        $user->nick, $num_wcards, $channel->disp_name);

    my $needed = 10 - $num_wcards;

    if ($needed < 1) {
        debug("%s doesn't need any more White Cards in %s game", $user->nick,
            $channel->disp_name);
        return;
    }

    # Are there discarded cards for this UserGame?
    my @discards = $ug->rel_usergamediscards;

    if (scalar @discards) {
        my $num_discards    = scalar @discards;
        my $discards_needed = $num_discards > $needed ? $needed : $num_discards;

        debug("There's %u cards on the discard pile for this user/game; taking %u"
           . " from there", $num_discards, $discards_needed);

        my @discard_insert = map {
            { user_game => $ug->id, wcardidx => $_->wcardidx }
        } @discards;

        # Back into the hand they go…
        $schema->resultset('UserGameHand')->populate(\@discard_insert);

        # Delete them out of the u_g_discards table again.
        my @discard_delete = map { $_->id } @discards;
        $schema->resultset('UserGameDiscard')->search(
            {
                id => { '-in' => \@discard_delete },
            }
        )->delete;

        $self->notify_new_wcards($ug, \@discards);

        # Now run topup again to pick up any extra we might need.
        $self->topup_hand($ug);
        return;
    }

    # How many White Cards are actually available?
    my $available_cards = $schema->resultset('WCard')->search(
        {
            game => $game->id,
        }
    )->count;

    if ($available_cards < $needed) {
        # There aren't enough White Cards left to populate this user's hand, so
        # populate the deck first.
        debug("White deck for game in %s is exhausted; reshuffling",
            $channel->disp_name);

        # Delete what is there first though, just to avoid any duplicate card
        # issues.
        $schema->resultset('WCard')->search({ game => $game->id })->delete;

        # Delete all the discard piles as well.
        my @usergames = $game->rel_usergames;
        my @ug_ids    = map { $_->id } @usergames;

        $schema->resultset('UserGameDiscard')->search(
            {
                user_game => { '-in' => \@ug_ids },
            }
        )->delete;

        $self->db_populate_cards($game, 'White');
    }

    debug("Dealing %u White Cards off the top for %s", $needed, $user->nick);

    # Grab the top $needed cards off this game's White deck…
    my @new = $schema->resultset('WCard')->search(
        {
            game => $game->id,
        },
        {
            order_by => { '-asc' => 'id' },
            rows     => $needed,
        },
    );

    # Construct an array of hashrefs representing the insert into the hand…
    my @to_insert = map {
        { user_game => $ug->id, wcardidx => $_->cardidx }
    } @new;

    # Actually do the insert…
    $schema->resultset('UserGameHand')->populate(\@to_insert);

    my @to_delete = map { $_->id } @new;

    # Now delete those cards from the White deck (because they now reside
    # in the user's hand.
    $schema->resultset('WCard')->search(
        {
            game => $game->id,
            id   => { '-in' => \@to_delete },
        }
    )->delete;

    # Sort them by "cardidx".
    @new = sort { $a->cardidx <=> $b->cardidx } @new;

    $self->notify_new_wcards($ug, \@new);
}

# A round has just started so each player will need their hand topping back up
# to 10 White Cards.
#
# Arguments:
#
# - Game Schema object
#
# Returns:
#
# Nothing.
sub topup_hands {
    my ($self, $game) = @_;

    my $schema  = $self->_schema;
    my $channel = $game->rel_channel;

    my @active_usergames = $game->rel_active_usergames;

    foreach my $ug (@active_usergames) {
        $self->topup_hand($ug);
    }
}

# Tell a user about the fact that some White Cards just got added to their
# hand. These cards will have come either from the WCard pile or from the
# UserGameDiscard pile.
#
# Arguments
#
# - The UserGame Schema object for this User/Game.
#
# - An arrayref of WCard *or* UserGameDiscard Schema objects representing the
#   new cards.
#
# Returns:
#
# Nothing.
sub notify_new_wcards {
    my ($self, $ug, $new) = @_;

    my $who  = $ug->rel_user->nick;
    my $deck = $self->_deck->{$ug->rel_game->deck};
    my $irc  = $self->_irc;

    my $num_added = scalar @{ $new };

    $irc->msg($who,
        sprintf("%u new White Card%s been dealt to you in %s:", $num_added,
            1 == $num_added ? ' has' : 's have',
            $ug->rel_game->rel_channel->disp_name));

    $self->notify_wcards($ug, $new);

    if ($num_added < 10) {
        my @active_usergames = $ug->rel_user->rel_active_usergames;

        if (scalar @active_usergames > 1) {
            # They're in more than one game, so they need to specify the channel.
            $irc->msg($who,
                sprintf(qq{To see your full hand, type "%s hand".},
                    $ug->rel_game->rel_channel->disp_name));
        } else {
            $irc->msg($who, qq{To see your full hand, type "hand".});
        }
    }
}

# List off a set of White Cards to a user.
#
# Arguments:
#
# - The UserGame Schema object for this User/Game.
# - An arrayref of Schema objects representing the cards. These can be either:
#   - ::WCard, representing cards from the deck
#   - ::UserGameHand, representing cards from the hand
#   - ::UserGameDiscard, representing cards from the discard pile.
#
#   If the object is a ::WCard then the accessor for the card index will be
#   "cardidx", otherwise it will be "wcardidx".
#
# Returns:
#
# Nothing.
sub notify_wcards {
    my ($self, $ug, $cards) = @_;

    my $who  = $ug->rel_user->nick;
    my $deck = $self->_deck->{$ug->rel_game->deck};
    my $irc  = $self->_irc;

    my $i = 0;

    # Don't number them unless this is a full hand, as the numbering would be
    # incorrect.
    my $numbering = scalar @{ $cards } >= 10 ? 1 : 0;

    foreach my $wcard (@{ $cards }) {
        $i++;

        my $index;

        if ($wcard->has_column('wcardidx')) {
            # This is a ::UserGameHand or a ::UserGameDiscard.
            $index = $wcard->wcardidx;
        } else {
            # This is a ::WCard.
            $index = $wcard->cardidx;
        }

        my $text = $deck->{White}->[$index];

        # Upcase the first character and add a period on the end unless it
        # already has some punctuation.
        $text = ucfirst($text);

        if ($text !~ /[\.\?\!]$/) {
            $text .= '.';
        }

        if ($numbering) {
            $irc->msg($who, sprintf("%2u. %s", $i, $text));
        } else {
            $irc->msg($who, "→ $text");
        }
    }
}

# Deal a new Black Card to the Card Tsar and tell the channel about it. This
# marks the start of a new hand.
#
# Arguments:
#
# - The Game Schema object for this game.
#
# Returns:
#
# Nothing.
sub deal_to_tsar {
    my ($self, $game) = @_;

    my $schema    = $self->_schema;
    my $irc       = $self->_irc;
    my $chan      = $game->rel_channel->disp_name;
    my @usergames = $game->rel_active_usergames;

    # First match only.
    my ($tsar) = grep { 1 == $_->is_tsar } @usergames;

    # Grab the top Black Card off this game's deck…
    my $new = $schema->resultset('BCard')->find(
        {
            game => $game->id,
        },
        {
            order_by => { '-asc' => 'id' },
            rows     => 1,
        },
    );

    if (not defined $new) {
        # Black deck ran out.
        debug("Black deck for game in %s is exhausted; reshuffling",
            $chan);
        $self->db_populate_cards($game, 'Black');
        $self->deal_to_tsar($game);
        return;
    }

    # Update the Game with the index of the current black card and the timers.
    my $now = time();

    $game->bcardidx($new->cardidx);
    $game->activity_time($now);
    $game->round_time($now);
    $game->update;

    # Discard the Black Card off the deck (because it's now part of the Game round).
    $schema->resultset('BCard')->find({ id => $new->id })->delete;

    # Notify every player about the new black card, so they don't have to leave
    # their privmsg window to continue playing.
    foreach my $ug (@usergames) {
        # Not if they're the Tsar though.
        next if (1 == $ug->is_tsar);

        $irc->msg($ug->rel_user->nick,
            sprintf("[%s] Time for the next Black Card:", $chan));
        $self->notify_bcard($ug->rel_user->nick, $game);
    }

    # Notify the channel about the new Black Card.
    $self->notify_bcard($chan, $game);
}

# Tell a channel or nick about the Black Card that has just been dealt.
#
# Arguments:
#
# - The target of the message (channel name or nickname).
# - The Game Schema object for this game.
#
# Returns:
#
# Nothing.
sub notify_bcard {
    my ($self, $who, $game) = @_;

    my $channel = $game->rel_channel;
    my $chan    = $channel->disp_name;
    my $deck    = $self->_deck->{$game->deck};
    my $text    = $deck->{Black}->[$game->bcardidx];

    foreach my $line (split(/\n/, $text)) {
        # Sometimes YAML leaves us with a trailing newline in the text.
        next if ($line =~ /^\s*$/);

        $self->_irc->msg($who, "→ $line");
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
sub do_priv_black {
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
        my $channel = $schema->resultset('Channel')->find(
            {
                name => $chan,
            }
        );

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
                "Sorry, you're going to have to tell me which channel's game you're"
               . " interested in.");
            $irc->msg($who, "Try again with \"/msg $my_nick #channel black\"");
            return;
        } else {
            # They're in more than one game so again no way to tell which one
            # they mean.
            $irc->msg($who,
                "Sorry, you appear to be in multiple games so you're going to have"
               . " to specify which one you mean.");
            $irc->msg($who, "Try again with \"/msg $my_nick #channel black\"");
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

    if ($tsar->rel_user->nick eq $who) {
        # They're the Card Tsar.
        $irc->msg($who, "You're the current Card Tsar!");
    } else {
        my $tsar      = $tsar->rel_user;
        my $tsar_nick = $tsar->disp_nick;

        $tsar_nick = $tsar->nick if (not defined $tsar_nick);

        $self->_irc->msg($who,
            sprintf("The current Card Tsar is %s", $tsar_nick));

        # Are they in a position to play a move?
        if (defined $usergame) {
            $irc->msg($who, "Use the \"Play\" command to make your play!");
        }
    }

}

# A user wants to make a play from their hand of White Cards. After sanity
# checks we'll take the play and then repeat it back to them so they can
# appreciate the full impact of their choice.
#
# They can make another play at any time up until when the Card Tsar views the
# cards.
sub do_priv_play {
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
            sprintf("Sorry, the game in %s isn't active at the moment, so no plays"
               . " are being accepted.", $channel->disp_name));
        return;
    }

    # Is there already a full set of plays for this game? If so then no more
    # changes are allowed.
    if ($self->hand_is_complete($game)) {
        $irc->msg($who,
            sprintf("All plays have already been made for this game, so no changes"
               . " now! We're now waiting on the Card Tsar (%s).",
               $game->rel_tsar_usergame->rel_user->nick));
        return;
    }

    # Are they the Card Tsar? The Tsar doesn't get to play!
    if (1 == $ug->is_tsar) {
        $irc->msg($who,
            sprintf("You're currently the Card Tsar for %s; you don't get to play"
               . " any White Cards yet!", $channel->disp_name));
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
               . qq{ "/msg $my_nick play 1 2" where "1" and "2" are the White Card}
               . qq{ numbers from your hand.});
        }
        return;
    }

    if (1 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*$/ and $1 > 0) {
            $first = $1;
        } else {
            $irc->msg($who, "Sorry, this Black Card needs one White Card and"
               . " \"$params\" doesn't look like a single, positive integer. Try"
               . " again!");
            return;
        }
    } elsif (2 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*(?:\s+|,|\&)\s*(\d+)\s*$/
                and $1 > 0 and $2 > 0) {
            $first  = $1;
            $second = $2;
        } else {
            $irc->msg($who,
                "Sorry, this Black Card needs two White Cards. Do it like this:");
            $irc->msg($who, qq{/msg $my_nick play 1 2});
            return;
        }

        if ($first == $second) {
            debug("%s tried to play two identical cards.", $who);
            $irc->msg($who, "You must play two different cards! Try again.");
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
        sprintf("Thanks. So this is your play for %s:", $channel->disp_name));

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
    if ($self->hand_is_complete($game)) {
        # Kill any timer that might be about to notify of plays.
        undef $self->_pn_timers->{$game->id};

        $irc->msg($channel->name, "All plays are in. No more changes!");

        $self->prep_plays($game);

        # Tell the channel about the collection of plays.
        $self->list_plays($game);

    } elsif ($is_new) {
        # Only bother to tell the channel if this is a new play.
        # User can then keep changing their play without spamming the channel.

        # Start a timer to notify about plays, as long as there isn't already a
        # timer running.
        #
        # The timer is 1/60th of the turnclock, minumum 60 seconds.
        my $after;
        $after = $self->_config->{turnclock} / 60;
        $after = 60 if ($after < 60);

        if (not defined $self->_pn_timers->{$game->id}) {
            $self->_pn_timers->{$game->id} = AnyEvent->timer(
                after => $after,
                cb    => sub { $self->notify_plays($game); },
            );
        }
    } else {
        # Hand isn't complete, we got a play but it wasn't a *new* play. So,
        # treat it as already notified.
        $self->_plays->{$game->id}->{$user->id}->{notified} = 1;
        $self->write_tallyfile;
    }
}

# Notify a channel about new plays that have been made.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub notify_plays {
    my ($self, $game) = @_;

    my $num_players = scalar $game->rel_active_usergames;
    my $num_plays   = $self->num_plays($game);
    my $waiting_on  = $num_players - $num_plays - 1;
    my $tally       = $self->_plays->{$game->id};
    my $channel     = $game->rel_channel;
    my $irc         = $self->_irc;

    # Plays that we haven't yet notified for.
    my $new_plays = 0;

    foreach my $uid (keys %{ $tally }) {
        if (0 == $tally->{$uid}->{notified}) {
            $new_plays++;
            $tally->{$uid}->{notified} = 1;
            $self->write_tallyfile;
        }
    }

    # If there's fewer than 4 players left to make their play then name them
    # explicitly.
    if ($waiting_on < 4) {
        $irc->msg($channel->disp_name,
            sprintf("%u %s recently played! %s", $new_plays,
                $new_plays == 1 ? 'person' : 'people',
                $self->build_waitstring($game)));
    } else {
        $irc->msg($channel->disp_name,
            sprintf("%u %s recently played! We're currently waiting on plays from"
               . " %u more people.", $new_plays,
               $new_plays == 1 ? 'person' : 'people', $waiting_on));
    }

    # Kill the timer again.
    undef $self->_pn_timers->{$game->id};
}

# Assemble a play from the current Black Card and some White Cards.
#
# Arguments:
#
# - The UserGame Schema object.
#
# - A scalar representing the index into the Black Card deck for the current
#   Black Card.
#
# - An arrayref of the UserGameHands for the White Cards played, in order.
#   There should be either one or two of them.
#
# Returns:
#
# - The formatted play.
sub build_play {
    my ($self, $ug, $bcardidx, $ughs) = @_;

    my $game     = $ug->rel_game;
    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};
    my $btext    = $deck->{Black}->[$bcardidx];

    if ($btext !~ /_{5,}/s) {
        # There's no blanks in this Black Card text so this will be a 1-card
        # answer, tacked on the end.
        $btext = sprintf("%s %s.",
            $btext, ucfirst($deck->{White}->[$ughs->[0]->wcardidx]));
        return $btext;
    }

    # Don't modify the passed-in $ughs.
    my @build_ughs = @{ $ughs };
    my $ugh        = shift @build_ughs;
    my $wtext      = $deck->{White}->[$ugh->wcardidx];

    $btext =~ s/_{5,}/$wtext/s;

    # If there's still a UserGameHand left, do it again.
    if (scalar @build_ughs) {
        $ugh   = shift @build_ughs;
        $wtext = $deck->{White}->[$ugh->wcardidx];

        $btext =~ s/_{5,}/$wtext/s;
    }

    # Remove extra punctuation.
    #
    # Sometimes a White Card will end with '!' or '?' and the placeholder in
    # the Black Card will also have '.' after it, resulting in doubled
    # punctuation like:
    #
    # → What will always get you laid? Surprise sex!.
    #
    # So squash any periods after '!' or '?'.
    $btext =~ s/([\.\?\!])\./$1/gs;

    # Upper-case things we put at the start.
    $btext =~ s/^(\S)/uc($1)/e;

    # Upper-case things we put after ".!?".
    $btext =~ s/([\.\?\!] \S)/uc($1)/gse;

    return $btext;
}

# Return the UserGameHand row corresponding to the n'th card for a given
# UserGame, ordered by wcardix.
#
# Arguments:
#
# - The UserGame Schema object.
# - The index (1-based, so "2" would be the second card).
#
# Returns:
#
# A UserGameHand Schema object or undef.
sub db_get_nth_wcard {
    my ($self, $ug, $idx) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('UserGameHand')->find(
        {
            user_game => $ug->id,
        },
        {
            order_by => { '-asc' => 'wcardidx' },
            rows     => 1,
            offset   => $idx - 1,
        },
    );
}

# Work out how many blanks (spaces for an answer) a particular Black Card has.
#
# A blank is defined as 5 or more underscores in a row.
#
# A Black Card with no such sequences of underscores has one implicit blank, at
# the end.
#
# Other possible numbers are 1 and 2.
#
# Arguments:
#
# - The Game Schema object.
#
# - A scalar representing the index into the Black Card deck for the current
#   Black Card.
#
# Returns:
#
# - How many blanks.
sub how_many_blanks {
    my ($self, $game, $idx) = @_;

    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};
    my $text     = $deck->{Black}->[$idx];

    if ($text !~ /_____/s) {
        # no blanks at all, so that's 1.
        return 1;
    }

    my @count = $text =~ m/_{5,}/gs;

    return scalar @count;
}

# Return the number of plays that have been made in this game so far.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# - The number of plays made so far.
sub num_plays {
    my ($self, $game) = @_;

    if (defined $self->_plays and defined $self->_plays->{$game->id}) {
        return scalar keys %{ $self->_plays->{$game->id} };
    } else {
        return 0;
    }
}

# Is a game's hand currently complete? A hand is complete when we have a play
# from every active user except the Card Tsar.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# - 0: Not yet complete.
#   1: Complete.
sub hand_is_complete {
    my ($self, $game) = @_;

    my $num_plays   = $self->num_plays($game);
    my $num_players = scalar $game->rel_active_usergames;

    return ($num_plays == ($num_players - 1));
}

# Is this user the game's Card Tsar?
#
# Arguments:
#
# - The User Schema object.
#
# - The Game Schema object.
#
# Returns:
#
# - 0: No.
#   1: Yes.
sub user_is_tsar {
    my ($self, $user, $game) = @_;

    my $schema = $self->_schema;

    my $ug = $schema->resultset('UserGame')->find(
        {
            user => $user->id,
            game => $game->id,
        }
    );

    return $ug->is_tsar;
}

# Inform the channel about the (completed) set of plays.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub list_plays {
    my ($self, $game) = @_;

    my $irc     = $self->_irc;
    my $channel = $game->rel_channel;
    my $tsar_ug = $game->rel_tsar_usergame;
    my $chan    = $channel->disp_name;

    # Hash ref of User ids.
    my $plays = $self->_plays->{$game->id};

    my $num_plays = scalar keys %{ $plays };

    my $header_length;

    # Go through the plays in the specified sequence order just in case Perl's
    # hash ordering is predictable.
    foreach my $uid (
        sort { $plays->{$a}->{seq} <=> $plays->{$b}->{seq} }
        keys %{ $plays }) {

        my $seq       = $plays->{$uid}->{seq};
        my $text      = $plays->{$uid}->{play};
        my $tsar_nick = $tsar_ug->rel_user->disp_nick;

        $tsar_nick = $tsar_ug->rel_user->ncik if (not defined $tsar_nick);

        if (1 == $seq) {
            $header_length = length("$tsar_nick: Which is the best play?");

            $irc->msg($chan, "$tsar_nick: Which is the best play?");
            $irc->msg($chan, '=' x $header_length);

        }

        foreach my $line (split(/\n/, $text)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);

            # Pad play number to two spaces if there's 10 or more of them.
            if ($num_plays > 9) {
                $irc->msg($chan, sprintf("%2u → %s", $seq, $line));
            } else {
                $irc->msg($chan, "$seq → $line");
            }
        }
    }

    $irc->msg($chan, '=' x $header_length);

}

# Work out who is still left to make their play.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# An array of UserGame objects that are yet to make their play, or undef if
# waiting on the Card Tsar.
sub waiting_on {
    my ($self, $game) = @_;

    if ($game->status != 2) {
        # This should not be called on an inactive game.
        debug("Can't use waiting_on on an inactive game");
        return undef;
    }

    if ($self->hand_is_complete($game)) {
        return undef;
    }

    # Some number of players have not yet made their play.

    my $tally       = $self->_plays->{$game->id};
    my $num_players = scalar $game->rel_active_usergames;
    my $num_plays   = $self->num_plays($game);
    my $waiting_num = $num_players - 1 - $num_plays;

    my @usergames = $game->rel_active_usergames;

    # Go through @usergames and build an array of UserGames that *haven't*
    # made their play yet. Skip the Card Tsar.
    my @to_play = grep {
        not exists $tally->{$_->user} and 0 == $_->is_tsar
    } @usergames;

    return @to_play;
}

# Build a string describing who or what the game is waiting on for progress.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Scalar string or undef if there was some problem.
sub build_waitstring {
    my ($self, $game) = @_;

    if ($game->status != 2) {
        # This should not be called on an inactive game.
        debug("Can't build a waitstring for an inactive game.");
        return;
    }

    my $waitstring = "We're currently waiting on ";

    if ($self->hand_is_complete($game)) {
        # If the hand is complete then we must be waiting on the Card Tsar.
        my $tsar = $game->rel_tsar_usergame;

        my $tsar_nick = $tsar->rel_user->disp_nick;

        $tsar_nick = $tsar->rel_user->nick if (not defined $tsar_nick);

        $waitstring .= sprintf("the Card Tsar (%s) to pick a winner.",
            $tsar_nick);
    } else {
        my @to_play = $self->waiting_on($game);

        if (1 == scalar @to_play) {
            my $pronoun = $to_play[0]->rel_user->pronoun;
            my $nick    = $to_play[0]->rel_user->disp_nick;

            $nick = $to_play[0]->rel_user->nick if (not defined $nick);

            $pronoun = "their" if (not defined $pronoun);

            $waitstring = sprintf("We're just waiting on %s to make %s"
               . " play.", $nick, $pronoun);
        } else {
            my @to_play_nicks = map {
                my $user = $_->rel_user;
                my $nick = $user->disp_nick;

                $nick = $user->nick if (not defined $nick);

                "$nick";
            } @to_play;

            my $last = pop @to_play_nicks;

            $waitstring .= sprintf("plays from %u people: %s and %s.",
                scalar @to_play, join(', ', @to_play_nicks), $last);
        }
    }

    return $waitstring;
}

# Delete any plays this user may have made in this game.
#
# Arguments:
#
# - The UserGame Schema object.
#
# Returns:
#
# Nothing.
sub delete_plays {
    my ($self, $ug) = @_;

    my $tally = $self->_plays->{$ug->game};

    delete $tally->{$ug->user} if (exists $tally->{$ug->user});
    $self->write_tallyfile;
}

# Write the tally of plays in the current round to a tally file on disk in case
# the bot restarts.
#
# Arguments:
#
# None.
#
# Returns:
#
# Nothing.
sub write_tallyfile {
    my ($self) = @_;

    debug("Writing tallyfile to %s", $self->_tallyfile);
    nstore $self->_plays, $self->_tallyfile;
}

# Load the tallyfile into the play tally if it exists.
#
# Arguments:
#
# None
#
# Returns:
#
# The tall structure if successful, an empty hashref otherwise.
sub load_tallyfile {
    my ($self) = @_;

    if (-r $self->_tallyfile) {
        debug("Loading play tally from %s", $self->_tallyfile);

        my $schema = $self->_schema;
        my $tally  = retrieve($self->_tallyfile);

        foreach my $game_id (keys %{ $tally }) {
            my $game = $schema->resultset('Game')->find(
                {
                    id => $game_id,
                },
                {
                    prefetch => 'rel_channel',
                }
            );

            if (not defined $game) {
                # The plays in the tallyfile somehow relate to a game that is
                # no longer in the database. Could be a nuked database.
                debug("  Ignoring plays for nonexistent game %u", $game_id);
                delete $tally->{$game_id};
                next;
            }

            debug("  Loaded %u plays from game in %s",
                scalar keys %{ $tally->{$game_id} },
                $game->rel_channel->disp_name);

            foreach my $user_id (keys %{ $tally->{$game_id} }) {
                debug("  %2u. %s", $tally->{$game_id}->{$user_id}->{seq},
                    $tally->{$game_id}->{$user_id}->{play});
            }
        }

        return $tally;
    } else {
        debug("No tally file to load");
        return {};
    }
}

# Discard the user's current hand of White Cards.
#
# Firstly the cards must be inserted into the users_games_discards table, so
# that if they ever deal in again they can get these same cards back.
#
# Arguments:
#
# - The UserGame Schema object.
#
# Returns:
#
# Nothing.
sub discard_hand {
    my ($self, $ug) = @_;

    my $schema = $self->_schema;

    my @wcards = $schema->resultset('UserGameHand')->search(
        { user_game => $ug->id }
    );

    my @discards = map {
        { user_game => $ug->id, wcardidx => $_->wcardidx }
    } @wcards;

    $schema->resultset('UserGameDiscard')->populate(\@discards);

    $schema->resultset('UserGameHand')->search(
        {
            user_game => $ug->id,
        }
    )->delete;
}

# The Game now has a full set of plays, so apply a random sequence number to them.
# Update game activity timer so Tsar has the full turnclock to choose a winner.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub prep_plays {
    my ($self, $game) = @_;

    $game->activity_time(time());
    $game->update;

    my $tally = $self->_plays->{$game->id};

    my $num_players = scalar $game->rel_active_usergames;

    # Assign random sequence order to the plays just in case Perl's
    # ordering of hash keys is predictable.
    my @sequence = shuffle (1 .. ($num_players - 1));

    my $i = 0;

    foreach my $uid (keys %{ $tally }) {
        $tally->{$uid}->{seq} = $sequence[$i];
        $i++;
    }

    $self->write_tallyfile;

    return;
}

# User wants to pick a winning play.
sub do_pub_winner {
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
            my $num_players = scalar $game->rel_active_usergames;

            $irc->msg($chan,
                sprintf("We need %u more player%s before we can start playing.",
                    4 - $num_players, (4 - $num_players) == 1 ? '' : 's'));
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
            sprintf("%s: Sorry, you're not the Card Tsar – that's %s.", $who,
                $tsar_nick));
        return;
    }

    # Is the game's hand actually complete?
    if (not $self->hand_is_complete($game)) {
        $irc->msg($chan, "$who: Sorry, not everyone has played their hand yet!");
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
        "$who: Sorry, I don't seem to have a record of a play with that number.");
}

# The round has ended, we know the winner, so the scores need to be adjusted.
#
# Arguments:
#
# - The User Schema object representing the user who has just won.
#
# - The Game Schema object the win relates to.
#
# Returns:
#
# The UserGame of the winner after their stats have been updated.
sub end_round {
    my ($self, $user, $game) = @_;

    my $schema = $self->_schema;

    $game->activity_time(time());
    $game->update;

    my $ug = $schema->resultset('UserGame')->find(
        {
            user => $user->id,
            game => $game->id,
        }
    );

    # Increment the win count of the winner.
    $ug->wins($ug->wins + 1);
    $ug->update;

    # Increment the hands count of everyone except the Card Tsar.
    $schema->resultset('UserGame')->search(
        {
            game    => $game->id,
            active  => 1,
            is_tsar => 0,
        }
    )->update({ hands => \'hands + 1' });

    # tsarcount / is_tsar is updated at the start of next round.

    return $ug;
}

# The round has ended so the tally of plays for this game should be cleared out.
# The cards played will be removed from each users' hand.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub cleanup_plays {
    my ($self, $game) = @_;

    my $tally  = $self->_plays->{$game->id};
    my $schema = $self->_schema;

    my @cards;

    foreach my $uid (keys %{ $tally }) {
        # 'ugh_ids' is an arrayref of ids of UserGameHands for what was played.
        foreach my $id (@{ $tally->{$uid}->{ugh_ids} }) {
            my $ugh = $schema->resultset('UserGameHand')->find({ id => $id });
            push(@cards, $ugh);
        }
    }

    # Now @cards is an array of UserGameHands that need to be deleted, so build
    # an array of just the ids.
    my @to_delete;
    foreach my $ugh (@cards) {
        my $white_deck = $self->_deck->{$game->deck}->{White};
        my $idx = $ugh->wcardidx;

        debug("Discarding played White Cards:");
        debug("%s:  %s", $ugh->rel_usergame->rel_user->nick, $white_deck->[$idx]);

        push(@to_delete, $ugh->id);
    }

    $schema->resultset('UserGameHand')->search(
        {
            id => { '-in' => \@to_delete },
        }
    )->delete;

    # Finally delete the plays from the tally.
    delete $self->_plays->{$game->id};
    $self->write_tallyfile;
}

# Announce the winner of the previous round in message to all of the players of
# that round.
#
# Arguments:
#
# - Game Schema object.
#
# - UserGame Schema object representing the winner.
#
# - Text of the winning play as a scalar string.
#
# Returns:
#
# Nothing.
sub announce_winner {
    my ($self, $game, $winner, $winplay) = @_;

    my $irc          = $self->_irc;
    my $current_tsar = $game->rel_tsar_usergame;
    my $chan         = $game->rel_channel->disp_name;

    # Message every player to tell them who the winner was, before moving on
    # with the new Card Tsar.
    my @active_usergames = $game->rel_active_usergames;

    foreach my $ug (@active_usergames) {
        # Don't message the current Tsar as presumably they were there when
        # they picked the winner.
        next if ($ug->id == $current_tsar->id);

        my $nick = $ug->rel_user->disp_nick;
        $nick = $ug->rel_user->nick if (not defined $nick);

        if ($ug->id == $winner->id) {
            # Congratulate winning user.
            $irc->msg($nick,
                sprintf("[%s] Congrats, you won! You now have %u Awesome"
                    . " Point%s! Your winning play was:", $chan, $winner->wins,
                    $winner->wins == 1 ? '' : 's'));
        } else {
            # Tell player about winner.
            my $pronoun = $winner->rel_user->pronoun;
            $pronoun = 'their' if (not defined $pronoun);

            $irc->msg($nick,
                sprintf("[%s] The winner was %s, who now has %u"
                    . " Awesome Point%s! %s winning play was:", $chan,
                    $nick, $winner->wins, $winner->wins == 1 ? '' : 's',
                    ucfirst($pronoun)));
        }

        foreach my $line (split(/\n/, $winplay)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);
            $irc->msg($nick, "→ $line");
        }
    }
}

# Make the next player the Card Tsar.
#
# This will be the active UserGame object with the next-highest id, as that is
# based on the order in which the players joined the game. If there is no such
# object then it should wrap around to the first object.
#
# Arguments:
#
# - A UserGame Schema object for the previous round's winner. undef if the Tsar
#   isn't being elected because of a win.
#
# - A string for the winning play. undef if the Tsar isn't being elected
#   because of a win.
#
# - The Game Schema object the win relates to.
#
# Returns:
#
# Nothing.
sub pick_new_tsar {
    my ($self, $winner, $winplay, $game) = @_;

    my $schema  = $self->_schema;
    my $irc     = $self->_irc;
    my $channel = $game->rel_channel;
    my $chan    = $channel->disp_name;

    my $current_tsar = $game->rel_tsar_usergame;

    my $new_tsar = $schema->resultset('UserGame')->find(
        {
            game   => $game->id,
            active => 1,
            id     => { '>' => $current_tsar->id },
        },
        {
            order_by => 'id ASC',
            rows     => 1,
        }
    );

    if (not defined $new_tsar) {
        # Wrap around to start of table.
        $new_tsar = $schema->resultset('UserGame')->find(
            {
                game   => $game->id,
                active => 1,
            },
            {
                order_by => 'id ASC',
                rows     => 1,
            }
        );
     }

     if (not defined $new_tsar) {
         $game->status(0);
         $game->update;

         $irc->msg($chan,
             "I couldn't work out who the next Card Tsar should be. This is"
            . " probably a bug. Going to have to pause the game. Report this!");
         return;
     }

     if (defined $winner) {
         $self->announce_winner($game, $winner, $winplay);
     }

     $current_tsar->is_tsar(0);
     $current_tsar->update;

     $new_tsar->is_tsar(1);
     $new_tsar->tsarcount($new_tsar->tsarcount + 1);
     $new_tsar->update;

     my $tsar_nick = $new_tsar->rel_user->disp_nick;

     $tsar_nick = $new_tsar->rel_user->nick if (not defined $tsar_nick);

     if (defined $winner) {
         my $nick = $winner->rel_user->disp_nick;

         $nick = $winner->rel_user->nick if (not defined $nick);

         my $winstring = sprintf("The winner is %s, who now has %u Awesome"
            . " Point%s!", $nick, $winner->wins, 1 == $winner->wins ? '' : 's');

         $irc->msg($chan,
             sprintf("%s The new Card Tsar is %s. Time for the next Black Card:",
                 $winstring, $tsar_nick));
     } else {
         $irc->msg($chan,
             sprintf("The new Card Tsar is %s. Time for the next Black Card:",
                 $tsar_nick));
     }

     $self->deal_to_tsar($game);
}

# Count the number of White Cards in a hand for a UserGame.
#
# Arguments:
#
# - The UserGame Schema object.
#
# Returns:
#
# Count of cards.
sub count_cards {
    my ($self, $ug) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('UserGameHand')->search(
        {
            user_game => $ug->id,
        }
    )->count;
}

# Check all active Games for idle timeout. If the UserGames being waited upon
# have idled longer than the turnclock then the least active one is forcibly
# resigned.
#
# The Game's activity timer will be updated if that happens, so that the
# remaining UserGames have chance to perform their action.
#
# Arguments:
#
# - The turnclock in seconds.
#
# Returns:
#
# Nothing.
sub check_idlers {
    my ($self, $turnclock) = @_;

    my $schema = $self->_schema;

    my $now    = time();
    my $cutoff = $now - $turnclock;

    # Any Game with activity < $cutoff has idled too long.
    my @idlegames = $schema->resultset('Game')->search(
        {
            -and => [
                status        => 2,
                activity_time => { '<'  => $cutoff },
                activity_time => { '!=' => 0 },
            ],
        },
        {
            prefetch => 'rel_channel',
        }
    );

    foreach my $game (@idlegames) {
        debug("Need to deal with idle game at %s, idle since %s with"
           . " cutoff %s", $game->rel_channel->disp_name,
           strftime("%FT%T", localtime($game->activity_time)),
           strftime("%FT%T", localtime($cutoff)));
        $self->punish_idler($game);
    }
}

# Forcibly resign the longest idler in a Game. If the game is waiting on the
# Card Tsar then they are the only one who can be punished. Otherwise the Tsar
# can never be resigned.
#
# Arguments:
#
# - The Game object we're acting on.
#
# Returns:
#
# Nothing.
sub punish_idler {
    my ($self, $game) = @_;

    my $schema = $self->_schema;

    my $idler;

    if ($self->hand_is_complete($game)) {
        # Punish Card Tsar.
        $idler = $game->rel_tsar_usergame;
        debug("Punishing idle Card Tsar in %s", $game->rel_channel->disp_name);
    } else {
        # Punish most idle player, but not Card Tsar.
        $idler = $schema->resultset('UserGame')->find(
            {
                'active'           => 1,
                'game'             => $game->id,
                'is_tsar'          => 0,
                'me.activity_time' => { '>' => 0 },
            },
            {
                order_by => 'me.activity_time ASC',
                prefetch => [qw/rel_user rel_game/],
                rows     => 1,
            }
        );
    }

    if (not defined $idler) {
        debug("Couldn't find any idlers to punish in %s!",
            $game->rel_channel->disp_name);
        return;
    }

    $self->force_resign($idler);
}


# Forcibly resign a player.
#
# The Game's activity timer will be updated if that happens, so that the
# remaining UserGames have chance to perform their action.
#
# Arguments:
#
# - The UserGame object we're acting on.
#
# Returns:
#
# Nothing.
sub force_resign {
    my ($self, $ug) = @_;

    my $user    = $ug->rel_user;
    my $game    = $ug->rel_game;
    my $channel = $game->rel_channel;
    my $schema  = $self->_schema;
    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();
    my $nick    = $user->disp_nick;

    $nick = $user->nick if (not defined $nick);

    debug("Resigning %s from game at %s due to idleness", $nick,
        $channel->disp_name);

    $irc->msg($channel->disp_name,
        sprintf("I'm forcibly resigning %s from the game due to idleness. Idle"
           . " since %s.", $nick,
           strftime("%FT%T", localtime($ug->activity_time))));

    $irc->msg($user->nick,
        sprintf("You've been forcibly resigned from the game in %s because you've"
           . " been idle since %s!", $channel->disp_name,
           strftime("%FT%T", localtime($ug->activity_time))));
    $irc->msg($nick,
        sprintf(qq{If you ever want to join in again, just type "%s: deal me in"}
           . qq{ in %s!}, $my_nick, $channel->disp_name));

    $self->resign($ug);

    $game->activity_time(time());
    $game->update;
}

# Find the UserGame for a given nickname in a Game.
#
# Arguments:
#
# - The nickname as a scalar string.
#
# - The Game Schema object.
#
# Returns:
#
# The UserGame Schema object or undef if not found.
sub db_get_nick_in_game {
    my ($self, $who, $game) = @_;

    my $user = $self->db_get_user($who);

    my @ugs = $user->rel_usergames;

    foreach my $ug (@ugs) {
        return $ug if ($ug->game == $game->id);
    }

    # Didn't find it.
    return undef;
}

# User wants to set a personal pronoun to be used instead of the default "their".
#
# We will allow max five characters, a-zA-Z.
sub do_priv_pronoun {
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

# Clear out any record of pokes that have been made so that new pokes can be
# sent if needed.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub clear_pokes {
    my ($self, $game) = @_;

    if (defined $self->_pokes->{$game->id}) {
        debug("Clearing pokes for game at %s", $game->rel_channel->disp_name);
        delete $self->_pokes->{$game->id};
    }
}

# We've seen a user perform some public action, so now check if we are waiting
# on them to do something in the game. If so, send them a poke in private
# message to attempt to hurry things along.
#
# Arguments:
#
# - User's nickname as scalar string.
#
# - Channel this happened in as scalar string.
#
# Returns:
#
# Nothing.
sub poke {
    my ($self, $nick, $chan) = @_;

    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();
    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        # Channel is not in our database so give up here.
        return;
    }

    my $game = $channel->rel_game;

    if (not defined $game or 2 != $game->status) {
        # Either there's no game or the game isn't active, so give up.
        return;
    }

    my $ug = $self->db_get_nick_in_game($nick, $game);

    if (not defined $ug or $ug->active != 1) {
        # They're not in the game.
        return;
    }

    if (exists $self->_pokes->{$game->id}->{$ug->user}) {
        # Already poked them, so give up.
        return;
    }

    if ($self->hand_is_complete($game)) {
        # If the hand is complete then we must be waiting on the card Tsar. Are
        # they the Card Tsar?
        if (1 == $ug->is_tsar) {
            debug("Poke %s into choosing a winner in %s.", $nick, $chan);
            $irc->msg($nick,
                qq{Hi! We're waiting on you to pick the winner in $chan. Please}
               . qq{ type "$my_nick: <number>" in the channel to do so. This is the}
               . qq{ only reminder I'll send!});
            $self->_pokes->{$game->id}->{$ug->user} = { when => time() };
        }
    } else {
        if ($game->round_time != 0) {
            my $now = time();

            # How old is the round? If it's less than turnclock divided by 60
            # seconds (min 60) then don't bother.
            my $poke_time = $self->_config->{turnclock} / 60;

            $poke_time = 60 if ($poke_time < 60);

            $poke_time += $game->round_time;

            if ($now <= $poke_time) {
                # Too soon.
                return;
            }
        }

        # We're waiting on some number of players to play their answers, so is
        # this one of them?
        if (not exists $self->_plays->{$game->id}->{$ug->user}
                and 0 == $ug->is_tsar) {
            debug("Poke %s into making their play in %s.", $nick, $chan);
            $irc->msg($nick,
                qq{Hi! We're waiting on you to make your play in $chan. Use the}
               . qq{ play command to make your play, the hand command to}
               . qq{ see your hand again, or the black command to see the Black}
               . qq{ Card. This is the only reminder I'll send!});
            $self->_pokes->{$game->id}->{$ug->user} = { when => time() };
        }
    }
}

1;
