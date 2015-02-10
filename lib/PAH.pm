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
our $VERSION = "0.1";

use utf8; # There's some funky literals in here
use Config::Tiny;
use strict;
use warnings;
use Moose;
use MooseX::Getopt;
with 'MooseX::Getopt';
use Try::Tiny;
use Data::Dumper;

use PAH::IRC;
use PAH::Log;
use PAH::Schema;

has config_file => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { "etc/pah-irc.conf" }
);

has ircname => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { "pah-irc $VERSION" }
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

sub BUILD {
  my ($self) = @_;

  my $config = Config::Tiny->read($self->config_file)
      or die Config::Tiny->errstr;
  # Only care about the root section for now.
  $self->{_config} = $config->{_};

  $self->{_pub_dispatch} = {
      'status'      => {
          sub        => \&do_pub_status,
          privileged => 0,
      },
      'start'       => {
          sub        => \&do_pub_start,
          privileged => 1,
      },
      'deal me in'  => {
          sub       => \&do_pub_dealin,
          privileged => 1,
      },
      'resign'      => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
      'deal me out' => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
  };

  $self->{_whois_queue} = {};
}

# The "main"
sub start {
    my ($self) = @_;

    $self->db_connect;

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

        my $num_players = scalar $game->rel_usergames;

        if ($num_players < 4) {
            $game->status(1); # Waiting for players.
            debug("Game for %s only had %u player(s) so I set it as waiting",
                $chan, $num_players);
        } else {
            $game->status(2); # We're on.
            debug("Game for %s has enough players so it's now active", $chan);
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

# Deal with a public command directed at us in a channel.
sub process_chan_command {
    my ($self, $sender, $chan, $cmd) = @_;

    # Downcase everything, even the command, as there currently aren't any
    # public commands that could use mixed case.
    $sender = lc($sender);
    $chan   = lc($chan);
    $cmd    = lc($cmd);

    my $disp = $self->_pub_dispatch;
    my $args = {
        nick => $sender,
        chan => $chan,
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
        do_pub_unknown($self, $args);
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
    my $target      = $cb_info->{target};

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
sub do_pub_unknown {
    my ($self, $args) = @_;

    my $chan = $args->{chan};
    my $who  = $args->{nick};

    $self->_irc->msg($chan,
        "$who: Sorry, that's not a command I recognise. See"
       . " https://github.com/grifferz/pah-irc#usage for more info.");
}

sub do_pub_status {
    my ($self, $args) = @_;

    my $chan   = $args->{chan};
    my $who    = $args->{nick};
    my $schema = $self->_schema;

    my $channel = $schema->resultset('Channel')->find(
        { 'name' => $chan },
    );

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
           . " a weird error that needs to be reported!");
       return;
    }

    my $my_nick = $self->_irc->nick();

    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->_irc->msg($chan,
            "$who: There's no game of Perpetually Against Humanity in here.");
        $self->_irc->msg($chan,
            "Want to start one? Anyone with a registered nickname can do so.");
        $self->_irc->msg($chan,
            "Just type \"$my_nick: start\" and find at least 3 friends.");
    } elsif (2 == $game->status) {
        $self->_irc->msg($chan,
            "$who: A game is active! We're currently waiting on NOT"
           . " IMPLEMENTED to NOT IMPLEMENTED.");
        $self->_irc->msg($chan, "The current Card Tsar is NOT IMPLEMENTED.");
        $self->_irc->msg($chan, "Top three players: NOT IMPLEMENTED.");
        $self->_irc->msg($chan, "Current Black Card:");
        $self->_irc->msg($chan, "NOT IMPLEMENTED.");
    } elsif (1 == $game->status) {
        my $num_players = scalar $game->rel_usergames;

        $self->_irc->msg($chan,
            "$who: A game exists but we only have $num_players player"
            . (1 == $num_players ? '' : 's') . ". Find me "
            . (4 - $num_players) . " more and we're on.");
        $self->_irc->msg($chan,
            "Any takers? Just type \"$my_nick: me\" and you're in.");
    } elsif (0 == $game->status) {
    } else {
        debug("Game for %s has an unexpected status (%u)", $chan,
            $game->status);
        $self->_irc->msg($chan,
            "$who: I'm confused about the state of the game, sorry. Report"
           . " this!");
    }
}

# User wants to start a new game in a channel.
sub do_pub_start {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $my_nick = $self->_irc->nick();
    my $schema  = $self->_schema;

    # Do we have a channel in the database yet? The only way to create a
    # channel is to be invited there, so there will not be any need to create
    # it here, and it's a weird error to not have it.
    my $channel = $schema->resultset('Channel')->find(
        { 'name' => $chan },
    );

    if (not defined $channel) {
        $self->_irc->msg($chan,
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
            $self->_irc->msg($chan,
                "$who: Sorry, there's already a game for this channel, though"
               . " it seems to be paused when it shouldn't be! Ask around?");
        } elsif (1 == $status) {
            my $count = scalar ($game->rel_usergames);

            $self->_irc->msg($chan,
                "$who: Sorry, there's already a game here but we only have"
               . " $count of minimum 4 players. Does anyone else want to"
               . " play?");
            $self->_irc->msg($chan,
                "Type \"$my_nick: me\" if you'd like to!");
        } elsif (2 == $status) {
            $self->_irc->msg($chan,
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

    my $user = $schema->resultset('User')->find_or_create(
        { nick => $who },
    );

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    my $usergame = $schema->resultset('UserGame')->create(
        {
            user => $user->id,
            game => $game->id,
        }
    );

    # Now tell 'em.
    $self->_irc->msg($chan,
        "$who: You're on! We have a game of Perpetually Against Humanity up in"
       . " here. 4 players minimum are required. Who else wants to play?");
    $self->_irc->msg($chan,
        "Say \"$my_nick: me\" if you'd like to!");
}

sub do_pub_dealin {
    my ($self, $args) = @_;

    my $chan = $args->{chan};
    my $who  = $args->{nick};

    $self->_irc->msg($chan, "$who: Sorry, not implemented yet!");
}

sub do_pub_resign {
    my ($self, $args) = @_;

    my $chan = $args->{chan};
    my $who  = $args->{nick};

    $self->_irc->msg($chan, "$who: Sorry, not implemented yet!");
}

1;
