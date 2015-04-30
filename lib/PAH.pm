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
our $VERSION = "0.8pre";

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
use PAH::JoinQ;
use PAH::Dispatch;

use PAH::Command::Pub;
use PAH::Command::Priv;

if (eval "use Git::Repository; 1") {
    my $r;

    eval {
        no warnings 'all';
        $r = Git::Repository->new;
    };

    if (defined $r) {
        my $tip = $r->run(qw/rev-parse --short HEAD/);

        if (defined $tip and length $tip) {
            $VERSION .= " ($tip)";
        }
    }
}

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
    isa => 'PAH::Dispatch',
    is  => 'ro',
);

has _priv_dispatch => (
    isa => 'PAH::Dispatch',
    is  => 'ro',
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

# Queue of users waiting to join games.
has _joinq => (
    isa => 'PAH::JoinQ',
    is  => 'ro',
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

  if (not defined $self->{_config}->{packs}) {
      $self->{_config}->{packs} = 'cah_uk';
  }

  $self->{_pub_dispatch}  = PAH::Dispatch->new;
  $self->{_priv_dispatch} = PAH::Dispatch->new;
  $self->{_conf_dispatch} = PAH::Dispatch->new;

  my $dpub  = $self->{_pub_dispatch};
  my $dpriv = $self->{_priv_dispatch};
  my $dconf = $self->{_conf_dispatch};

  # Unprivileged commands.
  foreach my $cmd (qw/status scores plays/) {
      $dpub->add_cmd($cmd, \&{ 'PAH::Command::Pub::' . $cmd }, 0);
  }

  # 'scores' aliases.
  foreach my $cmd (qw/stats/) {
      $dpub->add_cmd($cmd, \&PAH::Command::Pub::scores, 0);
  }

  # Privileged commands.
  foreach my $cmd (qw/start dealin resign winner/) {
      $dpub->add_cmd($cmd, \&{ 'PAH::Command::Pub::' . $cmd }, 1);
  }

  # 'dealin' aliases.
  foreach my $cmd (qw/me me! dealmein/) {
      $dpub->add_cmd($cmd, \&PAH::Command::Pub::dealin, 1);
  }

  # 'resign' aliases.
  foreach my $cmd (qw/dealmeout retire quit/) {
      $dpub->add_cmd($cmd, \&PAH::Command::Pub::resign, 1);
  }

  # Unprivileged commands.
  foreach my $cmd (qw/black status scores plays deck/) {
      $dpriv->add_cmd($cmd, \&{ 'PAH::Command::Priv::' . $cmd }, 0);
  }

  # 'scores' aliases.
  foreach my $cmd (qw/stats/) {
      $dpriv->add_cmd($cmd, \&PAH::Command::Priv::scores, 0);
  }

  # Privileged commands.
  foreach my $cmd (qw/hand play config/) {
      $dpriv->add_cmd($cmd, \&{ 'PAH::Command::Priv::' . $cmd }, 1);
  }

  # 'hand' aliases.
  foreach my $cmd (qw/list/) {
      $dpriv->add_cmd($cmd, \&PAH::Command::Priv::hand, 1);
  }

  # 'config' aliases.
  foreach my $cmd (qw/set setting settings/) {
      $dpriv->add_cmd($cmd, \&PAH::Command::Priv::config, 1);
  }

  # Config sub-commands.
  foreach my $cmd (qw/chatpoke pronoun/) {
      $dconf->add_cmd($cmd, \&{ 'PAH::Command::Priv::config_' . $cmd }, 0);
  }

  $self->{_whois_queue} = {};

  $self->{_deck} = PAH::Deck->new($self->{_config}->{packs});

  my $deck = $self->{_deck};

  debug("Loaded packs:");
  foreach my $pd ($deck->pack_descs) {
      debug("  %s", $pd);
  }
  debug("Deck has %u Black Cards, %u White Cards",
      $deck->count('Black'), $deck->count('White'));

  $self->{_last}      = {};
  $self->{_pn_timers} = {};
  $self->{_intro}     = {};
  $self->{_pokes}     = {};
  $self->{_joinq}     = undef;
}

# The "main"
sub start {
    my ($self) = @_;

    $self->db_connect;
    $self->{_joinq} = PAH::JoinQ->new($self->_schema);
    $self->{_plays} = $self->load_tallyfile;

    $self->db_sanity_check_hands;
    $self->db_sanity_check_packs;

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
    my $channel = $schema->resultset('Channel')->find(
        {
            name => $name,
        },
        {
            prefetch => 'rel_game',
        },
    );

    return unless (defined $channel);

    my $game = $channel->rel_game;

    return unless (defined $game);

    debug("%s appears to have a game in existence…", $chan);

    if (0 == $game->status) {
        debug("…and it's currently paused so I'm going to activate it");

        my $num_players = $game->rel_active_usergames->count;

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
        debug("Somehow got a join event for a channel %s we have no knowledge"
            . " of", $chan);
        return;
    }

    my $game = $channel->rel_game;

    if (not defined $game or 0 == $game->status) {
        # Game has never existed, so keep quiet.
        debug("Not introducing %s to game at %s because it isn't running",
            $nick, $chan);
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
            sprintf(qq{Hi! I'm currently running a game of}
                . qq{ Perpetually Against Humanity in %s. Are you}
                . qq{ interested in playing?}, $chan));
    } else {
        $irc->msg($nick,
            sprintf(qq{Hi! I'm currently gathering players for a game of}
                . qq{ Perpetually Against Humanity in %s. Are you}
                . qq{ interested in joining?}, $chan));
    }

    $irc->msg($nick,
        qq{If so then just type "$my_nick: deal me in" in the channel.});
    $irc->msg($nick,
        qq{See https://github.com/grifferz/pah-irc for more info. I won't}
        . qq{ bother you again if you're not interested!});
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
    my $irc    = $self->_irc;

    my @welcoming_chans = $schema->resultset('Channel')->search(
        { welcome => 1 }
    )->all;

    my $already_in = $irc->channel_list;

    foreach my $channel (@welcoming_chans) {
        # Are we already in it?
        next if (defined $already_in->{$channel->name});

        debug("Looks like I'm welcome in %s; joining…", $channel->disp_name);
        $irc->send_srv(JOIN => $channel->name);
    }
}

# Deal with a possible command directed at us in private message.
sub process_priv_command {
    my ($self, $sender, $cmd) = @_;

    # Downcase everything as there currently aren't any private commands that
    # could use mixed case.
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

    if ($cmd =~ /pronoun/i) {
        # "pronoun" command was moved under "config pronoun", so change $cmd to
        # "config" and stuff "pronoun" onto the start of $rest.
        $cmd = 'config';

        if (defined $rest) {
            $rest = "pronoun $rest";
        } else {
            $rest = 'pronoun';
        }
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

    if ($disp->cmd_exists($cmd)) {
        my $sub = $disp->get_cmd($cmd);

        if (! $disp->is_privileged($cmd)) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $sub->($self, $args);
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
                    callback => $sub,
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

    if ($disp->cmd_exists($cmd)) {
        my $sub =  $disp->get_cmd($cmd);

        if (! $disp->is_privileged($cmd)) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $sub->($self, $args);
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
                    callback => $sub,
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
    $callback->($self, $cb_args);
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

    if ($self->round_is_complete($game)) {
        # Waiting on Card Tsar.
        $waitstring = sprintf("Waiting on %s to pick the winning play.",
            $tsar_nick);
    } else {
        my @to_play     = $self->waiting_on($game);
        my $num_waiting = scalar @to_play;

        if ($num_waiting == 1) {
            # Only one person, so shame them.
            my $user    = $to_play[0]->rel_user;
            my $setting = $user->rel_setting;
            my $pronoun = do {
                if (defined $setting
                        and defined $setting->pronoun) { $setting->pronoun }
                else                                   { 'their' }
            };

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

    # $punishment_in can actually go negative if several players have run out
    # the turnclock. Since idling is only checked once per minute, in that case
    # the next punishment will be in less than a minute.
    if ($punishment_in < 60) {
        $irc->msg($target,
            sprintf("%s%s Round started about %s ago. Idle punishment in"
               . " less than a minute.", $is_nick ? "[$chan] " : '',
               $waitstring, concise(duration($started_ago, 2))));
    } else {
       $irc->msg($target,
           sprintf("%s%s Round started about %s ago. Idle punishment in"
              . " about %s.", $is_nick ? "[$chan] " : '', $waitstring,
               concise(duration($started_ago, 2)),
               concise(duration($punishment_in, 2))));
    }

    my $user;

    $user = $self->db_get_user($target) if ($is_nick);

    if ($is_nick and defined $self->_plays
            and defined $self->_plays->{$game->id}
            and defined $self->_plays->{$game->id}->{$user->id}) {
        # This is a private status command and they've made a play in this
        # round, so tell them about it.
        $irc->msg($target,
            sprintf("[%s] The Card Tsar is %s. Your play:", $chan,
                $tsar_nick));

        my $play = $self->_plays->{$game->id}->{$user->id}->{play};

        foreach my $line (split(/\n/, $play)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);

            $irc->msg($target, "→ $line");
        }
    } else {
        # Either this is public, or they haven't made a play in this round (may
        # be the Card Tsar) so just tell them the Black Card.
        $irc->msg($target,
            sprintf("%sThe Card Tsar is %s; current Black Card:",
                $is_nick ? "[$chan] " : '', $tsar_nick));

        $self->notify_bcard($target, $game);
    }
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

    my $was_complete = $self->round_is_complete($game);

    my $now = time();

    # Are they the Card Tsar?
    if (1 == $ug->is_tsar) {
        debug("%s was Tsar for %s", $who, $chan);

        if (2 == $game->status and $was_complete) {
            debug("Played cards in %s have been seen so must be discarded",
                $chan);
            $self->cleanup_plays($game);
        } else {
            # Just delete everyone's plays.
            delete $self->_plays->{$game->id};
            $self->write_tallyfile;
        }

        # And discard their hand of White Cards.
        $self->discard_hand($ug);

        # Mark them as inactive.
        $ug->activity_time($now);
        $ug->active(0);
        $ug->update;

        # Elect the next Tsar.
        $self->pick_new_tsar(undef, undef, $game);

        # Give the players any new cards they need.
        $self->topup_hands($game);

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
    my $player_count = $game->rel_active_usergames->count;

    if ($player_count < 4) {
        my $my_nick = $irc->nick();

        debug("Resignation of %s in %s has brought the game down to %u"
           . " player%s", $who, $chan, $player_count,
           1 == $player_count ? '' : 's');
        $game->status(1);
        $game->update;

        $irc->msg($chan,
            sprintf("That's taken us down to %u player%s. Game paused until we"
               . " get back up to 4.", $player_count,
               1 == $player_count ? '' : 's'));
        $irc->msg($chan,
            qq{Would anyone else like to play? If so type}
           . qq{ "$my_nick: me"});
    }

    # Has this actually completed the round (i.e. we were waiting on the user
    # who just resigned)?
    if (2 == $game->status and $self->round_is_complete($game)) {
        if (! $was_complete) {
            # Before this resignation the round wasn't complete, but now it is,
            # so update the game timer. Otherwise the Card Tsar will only get a
            # very short time to pick a winner!
            $game->activity_time($now);
            $game->update;
        }

        debug("Resignation of %s in %s has completed the round", $who, $chan);
        $irc->msg($chan,
            "Now that $who was dealt out, all the plays are in."
           . " No more changes!");
        $self->prep_plays($game);
        $self->list_plays($game, $chan);
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

    my $schema = $self->_schema;
    my $packs  = $game->packs;
    my $deck   = $self->_deck;

    my $num_cards = $deck->count($color);

    debug("Shuffling deck of %u %s Cards from packs [%s], for game at %s",
        $num_cards, $color, $packs, $game->rel_channel->disp_name);

    my @card_indices = 0 .. ($num_cards - 1);

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
            push(@hand_card_indices,
                map { $_->wcardidx } $ug->rel_usergamehands);
        }

        # Remove the hand cards from the deck's cards.
        my %seen;
        @seen{@card_indices} = ( );
        delete @seen { @hand_card_indices };

        debug("Dropped %u cards which are currently in %s players' hands",
            scalar @hand_card_indices, $game->rel_channel->disp_name);
        @card_indices = keys %seen;
    }

    @card_indices = shuffle @card_indices;

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
            sprintf("Turns in this game can take around %s (mostly done"
               . " within %s though), so there's no need to rush.",
               duration($turnclock * 2), duration($turnclock)));
        $irc->msg($who,
            qq{If you need to stop playing though, please type}
           . qq{ "$my_nick: resign" in $chan so the others aren't kept}
           . qq{ waiting.});
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
    my @wcards     = $ug->rel_usergamehands;
    my $num_wcards = scalar @wcards;
    my $channel    = $game->rel_channel;

    debug("%s currently has %u White Cards in %s game",
        $user->nick, $num_wcards, $channel->disp_name);

    my $needed = 10 - $num_wcards;

    if ($needed < 1) {
        debug("%s doesn't need any more White Cards in %s game", $user->nick,
            $channel->disp_name);
        return;
    }

    # Start off with 10 available card positions.
    my %avail_pos_hash = map { $_ => 1 } 1 .. 10;

    # Gte rid of positions that we already have.
    foreach my $wcard (@wcards) {
        delete $avail_pos_hash{$wcard->pos};
    }

    # Put that into an array ordered by increasing position.
    my @avail_pos = sort { $a <=> $b } keys %avail_pos_hash;

    debug("  Available card positions: %s", join(' ', @avail_pos));

    # Sanity check that the number of available positions is the same as the
    # number of cards needed.
    if (scalar @avail_pos != $needed) {
        debug("%s has %u available hand positions but needs %u cards",
            $user->nick, scalar @avail_pos, $needed);
        return;
    }

    # Are there discarded cards for this UserGame?
    my @discards = $ug->rel_usergamediscards;

    if (scalar @discards) {
        my $num_discards    = scalar @discards;
        my $discards_needed = $num_discards > $needed ? $needed : $num_discards;

        debug("There's %u cards on the discard pile for this user/game; taking"
           . " %u from there", $num_discards, $discards_needed);

        my @discard_insert;

        foreach my $d (@discards) {
            my $new_pos = shift @avail_pos;

            my $new_card = {
                user_game => $ug->id,
                wcardidx  => $d->wcardidx,
                pos       => $new_pos,
            };

            push(@discard_insert, $new_card);
        }

        # Back into the hand they go…
        $schema->resultset('UserGameHand')->populate(\@discard_insert);

        # Delete them out of the u_g_discards table again.
        my @discard_delete = map { $_->id } @discards;
        $schema->resultset('UserGameDiscard')->search(
            {
                id => { '-in' => \@discard_delete },
            }
        )->delete;

        my @added_pos = map { $_->{pos} } @discard_insert;

        my @added = $schema->resultset('UserGameHand')->search(
            {
                user_game => $ug->id,
                pos       => { '-in' => \@added_pos },
            },
            {
                order_by => 'pos ASC',
            }
        );

        $self->notify_new_wcards($ug, \@added);

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
        $self->db_delete_discards($game);

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
    my @to_insert;

    foreach my $n (@new) {
        my $new_pos = shift @avail_pos;

        my $new_card = {
            user_game => $ug->id,
            wcardidx  => $n->cardidx,
            pos       => $new_pos,
        };

        push(@to_insert, $new_card);
    }

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

    my @added_pos = map { $_->{pos} } @to_insert;

    my @added = $schema->resultset('UserGameHand')->search(
        {
            user_game => $ug->id,
            pos       => { '-in' => \@added_pos },
        },
        {
            order_by => 'pos ASC',
        }
    );

    $self->notify_new_wcards($ug, \@added);
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
# - An arrayref of UserGameHand Schema objects representing the new cards.
#
# Returns:
#
# Nothing.
sub notify_new_wcards {
    my ($self, $ug, $new) = @_;

    my $user = $ug->rel_user;
    my $chan = $ug->rel_game->rel_channel->disp_name;
    my $irc  = $self->_irc;
    my $who  = do {
        if (defined $user->disp_nick) { $user->disp_nick }
        else                          { $user->nick }
    };

    my $num_added = scalar @{ $new };

    $irc->msg($who,
        sprintf("%u new White Card%s been dealt to you in %s:",
            $num_added, 1 == $num_added ? ' has' : 's have', $chan));

    $self->notify_wcards($ug, $new);

    if ($num_added < 10) {
        my @active_usergames = $user->rel_active_usergames;

        if (scalar @active_usergames > 1) {
            # They're in more than one game, so they need to specify the
            # channel.
            $irc->msg($who, qq{To see your full hand, type "$chan hand".});
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
# - An arrayref of UserGameHand Schema objects representing the cards.
#
# Returns:
#
# Nothing.
sub notify_wcards {
    my ($self, $ug, $cards) = @_;

    my $user = $ug->rel_user;
    my $deck = $self->_deck;
    my $irc  = $self->_irc;
    my $who  = do {
        if (defined $user->disp_nick) { $user->disp_nick }
        else                          { $user->nick }
    };

    foreach my $wcard (@{ $cards }) {
        my $index;

        $index = $wcard->wcardidx;

        my $text = $deck->white($index);

        # Upcase the first character and add a period on the end unless it
        # already has some punctuation.
        $text = ucfirst($text);

        if ($text !~ /[\.\?\!]$/) {
            $text .= '.';
        }

        $irc->msg($who, sprintf("%2u. %s", $wcard->pos, $text));
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

    # Discard the Black Card off the deck (because it's now part of the Game
    # round).
    $schema->resultset('BCard')->find({ id => $new->id })->delete;

    my $tsar_nick = do {
        if (defined $tsar->rel_user->disp_nick) { $tsar->rel_user->disp_nick }
        else                                    { $tsar->rel_user->nick }
    };

    # Notify every player about the new black card, so they don't have to leave
    # their privmsg window to continue playing.
    foreach my $ug (@usergames) {
        # Not if they're the Tsar though.
        next if (1 == $ug->is_tsar);

        my $user = $ug->rel_user;
        my $who  = do {
            if (defined $user->disp_nick) { $user->disp_nick }
            else                          { $user->nick }
        };

        $irc->msg($who,
            sprintf("[%s] The new Card Tsar is %s. Time for the next"
               . " Black Card:", $chan, $tsar_nick));
        $self->notify_bcard($who, $game);
    }

    # Notify the channel about the new Black Card.
    $self->notify_bcard($chan, $game);

    # Deal in any users who were waiting (as long as they're still in the
    # channel).
    $self->dealin_waiters($game);
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
    my $deck    = $self->_deck;
    my $text    = $deck->black($game->bcardidx);

    foreach my $line (split(/\n/, $text)) {
        # Sometimes YAML leaves us with a trailing newline in the text.
        next if ($line =~ /^\s*$/);

        $self->_irc->msg($who, "→ $line");
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

    my $num_players = $game->rel_active_usergames->count;
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
            sprintf("%u %s recently played! We're currently waiting on"
               . " plays from %u more people.", $new_plays,
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

    my $game  = $ug->rel_game;
    my $deck  = $self->_deck;
    my $btext = $deck->black($bcardidx);

    if ($btext !~ /_{5,}/s) {
        # There's no blanks in this Black Card text so this will be a 1-card
        # answer, tacked on the end.
        $btext = sprintf("%s %s.", $btext,
            ucfirst($deck->white($ughs->[0]->wcardidx)));
    } else {
        # Don't modify the passed-in $ughs.
        my @build_ughs = @{ $ughs };
        my $ugh        = shift @build_ughs;
        my $wtext      = $deck->white($ugh->wcardidx);

        $btext =~ s/_{5,}/$wtext/s;

        # If there's still a UserGameHand left, do it again.
        if (scalar @build_ughs) {
            $ugh   = shift @build_ughs;
            $wtext = $deck->white($ugh->wcardidx);

            $btext =~ s/_{5,}/$wtext/s;
        }
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

# Return the UserGameHand row corresponding to the particular card position for
# a given UserGame.
#
# Arguments:
#
# - The UserGame Schema object.
# - The position in the hand (1-based, so "2" would be the second card).
#
# Returns:
#
# A UserGameHand Schema object or undef.
sub db_get_nth_wcard {
    my ($self, $ug, $pos) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('UserGameHand')->find(
        {
            user_game => $ug->id,
            pos       => $pos,
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

    my $deck = $self->_deck;
    my $text = $deck->black($idx);

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

# Is a game's current round now complete? A round is complete when we have a
# play from every active user except the Card Tsar.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# - 0: Not yet complete.
#   1: Complete.
sub round_is_complete {
    my ($self, $game) = @_;

    my $num_plays   = $self->num_plays($game);
    my $num_players = $game->rel_active_usergames->count;

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

    if (not defined $ug) {
        return 0;
    }

    return $ug->is_tsar;
}

# Inform the channel or a nickname about the (completed) set of plays.
#
# Arguments:
#
# - The Game Schema object.
#
# - The target of the output, either a channel or a nick as a scalar string.
#
# Returns:
#
# Nothing.
sub list_plays {
    my ($self, $game, $target) = @_;

    my $irc       = $self->_irc;
    my $channel   = $game->rel_channel;
    my $tsar_ug   = $game->rel_tsar_usergame;
    my $chan      = $channel->disp_name;
    my $tsar_user = $tsar_ug->rel_user;
    my $tsar_nick = do {
        if (defined $tsar_user->disp_nick) { $tsar_user->disp_nick }
        else                               { $tsar_user->nick }
    };

    my $is_nick = 1;

    if ($target =~ /^[#\&]/) {
        $is_nick = 0;
    }

    # Hash ref of User ids.
    my $plays = $self->_plays->{$game->id};

    my $num_plays = scalar keys %{ $plays };

    my $header_length;

    # Go through the plays in the specified sequence order just in case Perl's
    # hash ordering is predictable.
    foreach my $uid (
        sort { $plays->{$a}->{seq} <=> $plays->{$b}->{seq} }
        keys %{ $plays }) {

        my $seq  = $plays->{$uid}->{seq};
        my $text = $plays->{$uid}->{play};

        if (1 == $seq) {
            my $header;

            if ($is_nick) {
                $header = "[$chan] ";

                if (lc($tsar_nick) eq lc($target)) {
                    $header        .= "You're the Card Tsar.";
                    $header_length = length($header) - 2; # bolds
                    $irc->msg($target, $header);
                } else {
                    $header        .= "The Card Tsar is $tsar_nick.";
                    $header_length = length($header) - 4; # bolds
                    $irc->msg($target, $header);
                }
            } else {
                $header        = "$tsar_nick: Which is the best play?";
                $header_length = length($header);
                $irc->msg($target, $header);
            }

            $irc->msg($target, '=' x $header_length);
        }

        my $first_line = 1;

        foreach my $line (split(/\n/, $text)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);

            # Pad play number to two spaces if there's 10 or more of them.
            my $num = do {
                if ($num_plays >= 10) { sprintf("%2u", $seq) }
                else                  { $seq }
            };

            # Show the play number on first line only.
            if ($first_line) {
                $irc->msg($target, "$num → $line");
                $first_line = 0;
            } else {
                $irc->msg($target,
                    sprintf("%s → %s", ' ' x length($num), $line));
            }
        }
    }

    $irc->msg($target, '=' x $header_length);
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

    if ($self->round_is_complete($game)) {
        return undef;
    }

    # Some number of players have not yet made their play.

    my $tally       = $self->_plays->{$game->id};
    my $num_players = $game->rel_active_usergames->count;
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

    if ($self->round_is_complete($game)) {
        # If the round is complete then we must be waiting on the Card Tsar.
        my $tsar = $game->rel_tsar_usergame;

        my $tsar_nick = $tsar->rel_user->disp_nick;

        $tsar_nick = $tsar->rel_user->nick if (not defined $tsar_nick);

        $waitstring .= sprintf("the Card Tsar (%s) to pick a winner.",
            $tsar_nick);
    } else {
        my @to_play = $self->waiting_on($game);

        if (1 == scalar @to_play) {
            my $user    = $to_play[0]->rel_user;
            my $setting = $user->rel_setting;

            my $pronoun = do {
                if (defined $setting
                        and defined $setting->pronoun) { $setting->pronoun }
                else                                   { 'their' }
            };

            my $nick = do {
                if (defined $user->disp_nick) { $user->disp_nick }
                else                          { $user->nick }
            };

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

# The Game now has a full set of plays, so apply a random sequence number to
# them.
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

    my $tally = $self->_plays->{$game->id};

    my $num_players = $game->rel_active_usergames->count;

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

# Report the plays for a completed round to either a nick or a channel. If the
# round isn't completed yet then just giver an error.
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
sub report_plays {
    my ($self, $game, $target) = @_;

    my $irc  = $self->_irc;
    my $chan = $game->rel_channel->name;

    # If the target is a nickname then we need to prepend the channel so they
    # know what we're talking about.
    my $is_nick = 1;

    if ($target =~ /^[#\&]/) {
        $is_nick = 0;
    }

    if (! $self->round_is_complete($game)) {
        # Still waiting on plays to come in.
        my @to_play     = $self->waiting_on($game);
        my $num_waiting = scalar @to_play;

        my $waitstring = sprintf("waiting on %u %s to make their play%s.",
            $num_waiting, $num_waiting == 1 ? 'person' : 'people',
            $num_waiting == 1 ? '' : 's');

        $irc->msg($target,
            sprintf("%sThe round isn't complete yet; %s",
                $is_nick ? "[$chan] " : '', $waitstring));
        return;
    }

    $self->list_plays($game, $target);
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
        my $deck = $self->_deck;
        my $idx  = $ugh->wcardidx;
        my $user = $ugh->rel_usergame->rel_user;
        my $nick = do {
            if (defined $user->disp_nick) { $user->disp_nick }
            else                          { $user->nick }
        };

        debug("Discarding played White Cards:");
        debug("%s:  %s", $nick, $deck->white($idx));

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

    my $winner_nick = $winner->rel_user->disp_nick;

    $winner_nick = $winner->rel_user->nick if (not defined $winner_nick);

    foreach my $ug (@active_usergames) {
        # Don't message the current Tsar as presumably they were there when
        # they picked the winner.
        next if ($ug->id == $current_tsar->id);

        my $user_nick = $ug->rel_user->disp_nick;
        $user_nick = $ug->rel_user->nick if (not defined $user_nick);

        if ($ug->id == $winner->id) {
            # Congratulate winning user.
            $irc->msg($user_nick,
                sprintf("[%s] Congrats, you won! You now have %u"
                   . " Awesome Point%s! Your winning play was:", $chan,
                   $winner->wins, $winner->wins == 1 ? '' : 's'));
        } else {
            # Tell player about winner.
            my $user    = $winner->rel_user;
            my $setting = $user->rel_setting;
            my $pronoun = do {
                if (defined $setting
                        and defined $setting->pronoun) { $setting->pronoun }
                else                                   { 'their' }
            };

            $irc->msg($user_nick,
                sprintf("[%s] The winner was %s, who now has %u"
                    . " Awesome Point%s! %s winning play was:", $chan,
                    $winner_nick, $winner->wins, $winner->wins == 1 ? '' : 's',
                    ucfirst($pronoun)));
        }

        foreach my $line (split(/\n/, $winplay)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);
            $irc->msg($user_nick, "→ $line");
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

    if (not defined $game) {
        die "Need a game object";
    }

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

         my $winstring = sprintf("The winner is %s, who now has %u"
            . " Awesome Point%s!", $nick, $winner->wins,
            1 == $winner->wins ? '' : 's');

         $irc->msg($chan,
             sprintf("%s The new Card Tsar is %s. Time for the next Black"
                . " Card:", $winstring, $tsar_nick));
     } else {
         $irc->msg($chan,
             sprintf("The new Card Tsar is %s. Time for the next Black"
                . " Card:", $tsar_nick));
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

    if ($self->round_is_complete($game)) {
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

    my $nick = do {
        if (defined $user->disp_nick) { $user->disp_nick }
        else                          { $user->nick }
    };

    debug("Resigning %s from game at %s due to idleness", $nick,
        $channel->disp_name);

    $irc->msg($channel->disp_name,
        sprintf("I'm forcibly resigning %s from the game due to idleness."
           . " Idle since %s.", $nick,
           strftime("%FT%T", localtime($ug->activity_time))));

    $irc->msg($nick,
        sprintf("You've been forcibly resigned from the game in %s because"
           . " you've been idle since %s!", $channel->disp_name,
           strftime("%FT%T", localtime($ug->activity_time))));
    $irc->msg($nick,
        sprintf(qq{If you ever want to join in again, just type}
           . qq{ "%s: deal me in" in %s!}, $my_nick, $channel->disp_name));

    $self->resign($ug);
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

    if ($self->round_is_complete($game)) {
        # If the hand is complete then we must be waiting on the card Tsar. Are
        # they the Card Tsar?
        if (1 == $ug->is_tsar) {
            debug("Poke %s into choosing a winner in %s.", $nick, $chan);
            $irc->msg($nick,
                qq{Hi! We're waiting on you to pick the winner in $chan.}
               . qq{ Please type "$my_nick: <number>" in the channel to do so.}
               . qq{ This is the only reminder I'll send!});
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
                qq{Hi! We're waiting on you to make your play in $chan.}
               . qq{ Use the play command to make your play, the hand}
               . qq{ command to see your hand again, or the black command}
               . qq{ to see the Black Card. This is the only reminder I'll}
               . qq{ send!});
            $self->_pokes->{$game->id}->{$ug->user} = { when => time() };
        }
    }
}

# Check that all hands in all games are valid, and fix them if necessary (and
# possible). This includes:
#
# - Do all cards have position numbers?
#
#   Prior to database version 9 hand cards did not have a position number, so
#   after schema upgrade their pos column will be NULL. They will need to be
#   sequentially re-ordered.
#
# Arguments:
#
# None.
#
# Returns:
#
# Nothing.
sub db_sanity_check_hands {
    my ($self) = @_;

    my $schema = $self->_schema;

    my $nulls = $schema->resultset('UserGameHand')->search(
        {
            pos => undef,
        },
    );

    my $null_cards = $nulls->count;

    if ($null_cards > 0) {
        debug("Found %u hand cards with NULL position; fixing…", $null_cards);

        my $ugs = $schema->resultset('UserGame')->search({});

        while (my $ug = $ugs->next) {
            $self->db_fix_hand_positions($ug);
        }
    }
}

# Re-order a player's hand so that the cards are sequentially numbered.
#
# Arguments:
#
# - UserGame Schema object whose hand is being fixed.
#
# Returns:
#
# Nothing.
sub db_fix_hand_positions {
    my ($self, $ug) = @_;

    my $schema = $self->_schema;

    my $nulls = $schema->resultset('UserGameHand')->search(
        {
            pos       => undef,
            user_game => $ug->id,
        },
        {
            order_by => 'id ASC',
        }
    );

    my $null_count = $nulls->count;

    my $nick = $ug->rel_user->disp_nick;

    $nick = $ug->rel_user->nick if (not defined $nick);

    debug("  Fixing %u NULL-position cards for %s in game %u…", $null_count,
        $nick, $ug->game);

    my $pos = 1;

    while (my $card = $nulls->next) {
        $card->pos($pos);
        $card->update;
        $pos++;
    }
}

# Switch the packs for an existing game to that specified by $self->_deck.
#
# Process goes like this:
#
# 1. Empty all discard piles.
# 2. Empty the decks for this game.
# 3. Check if the current Black Card text already exists in the new Black deck.
#    - Yes? Update Black Card index in games table to be index of existing card.
#    - No? Append Black Card on end of deck, update Black Card index in games
#          table to be new index.
# 4. Update all rows in users_games_hands for this game to have NULL wcardidx
#    so there won't be any constraint violations when we are fixing the
#    wcardidx later.
# 5. For each White Card that is in the hands of all players in this game:
#    1. Does this White Card text already exist in the new White deck?
#       - Yes? Update White Card index in users_games_hands to be index of
#         existing card.
#       - No? Append White Card on the end of deck, update White Card index in
#         users_games_hands to be the new index.
# 6. Re-populate game's decks (bcards and wcards tables).
#
# Arguments:
#
# - Game Schema object.
#
# Returns:
#
# Nothing.
sub db_switch_packs {
    my ($self, $game) = @_;

    my $schema        = $self->_schema;
    my $deck          = $self->_deck;
    my $current_packs = join(' ', $deck->packs);
    my $their_deck    = PAH::Deck->new($game->packs);

    debug("  Deleting all discard piles…");

    my $count = $self->db_delete_discards($game);

    debug("    …Deleted %u cards", $count) if ($count);

    debug("  Deleting bcards…");
    $schema->resultset('BCard')->search({ game => $game->id })->delete;
    debug("  Deleting wcards…");
    $schema->resultset('WCard')->search({ game => $game->id })->delete;

    my $cur_bcardidx = $game->bcardidx;

    if (defined $cur_bcardidx) {
        my $cur_bcardtxt = $their_deck->black($cur_bcardidx);

        my $new_bcardidx = $deck->find('Black', $cur_bcardtxt);

        if (defined $new_bcardidx) {
            if ($new_bcardidx != $cur_bcardidx) {
                debug("  Their Black Card %u exists as %u in new deck;"
                   . " adjusting…", $cur_bcardidx, $new_bcardidx);
                $game->bcardidx($new_bcardidx);
            } else {
                debug("  Black Cards identical (%u)", $cur_bcardidx);
            }
        } else {
            debug("  Their Black Card %u is not in new deck; appending…",
                $cur_bcardidx);
            $new_bcardidx = $deck->append('Black', $cur_bcardtxt);
            $game->bcardidx($new_bcardidx);
        }
    }

    my @usergames = $game->rel_usergames;
    my @ug_ids = map { $_->id } @usergames;

    debug("  Fixing up White Cards in hand for %u players…", scalar @ug_ids);

    # Get the current mappings of ugh id to card text.
    my $cards = $schema->resultset('UserGameHand')->search(
        {
            user_game => { '-in' => \@ug_ids },
        }
    );

    my %texts;

    while (my $card = $cards->next) {
        $texts{$card->id} = $their_deck->white($card->wcardidx);
    }

    debug("    Setting indices to NULL…");
    $schema->resultset('UserGameHand')->search(
        {
            user_game => { '-in' => \@ug_ids },
        }
    )->update({ wcardidx => undef });

    $cards = $schema->resultset('UserGameHand')->search(
        {
            user_game => { '-in' => \@ug_ids },
        },
        {
            prefetch => {
                'rel_usergame' => 'rel_user',
            }
        }
    );

    while (my $card = $cards->next) {
        my $user         = $card->rel_usergame->rel_user;
        my $cur_wcardtxt = $texts{$card->id};
        my $new_wcardidx = $deck->find('White', $cur_wcardtxt);

        my $nick = do {
            if (defined $user->disp_nick) { $user->disp_nick }
            else                          { $user->nick }
        };

        if (defined $new_wcardidx) {
            debug("    %s has White Card that already exists as %u in new deck;"
               . " adjusting…", $nick, $new_wcardidx);
            $card->wcardidx($new_wcardidx);
        } else {
            debug("    %s has a White Card that is not in new deck; appending…",
                $nick);
            $new_wcardidx = $deck->append('White', $cur_wcardtxt);
            $card->wcardidx($new_wcardidx);
        }

        $card->update;
    }

    $game->packs($current_packs);
    $game->update;

    debug("  Repopulating decks for this game…");
    foreach my $color (qw/Black White/) {
        $self->db_populate_cards($game, $color);
    }
}

# Check that every game is using the current set of packs.
#
# If a game is not using the current pack then we'll have to hackishly fix
# things up.
#
# Arguments:
#
# None.
#
# Returns:
#
# Nothing.
sub db_sanity_check_packs {
    my ($self) = @_;

    my $schema        = $self->_schema;
    my $deck          = $self->_deck;
    my $current_packs = join(' ', $deck->packs);

    my $games = $schema->resultset('Game')->search(
        {
            packs => { '!=' => $current_packs },
        },
        {
            prefetch => 'rel_channel',
        }
    );

    while (my $game = $games->next) {
        debug("Game in %s has packs '%s' but we've loaded '%s'; fixing up…",
            $game->rel_channel->disp_name, $game->packs, $current_packs);

        # All this in a transaction.
        $schema->txn_do(sub {
            $self->db_switch_packs($game);
        });
    }
}

# Delete all discard piles for a given game.
#
# Arguments:
#
# - Game Schema object.
#
# Returns:
#
# Number of cards (rows) deleted.
sub db_delete_discards {
    my ($self, $game) = @_;

    my $schema    = $self->_schema;
    my @usergames = $game->rel_usergames;
    my @ug_ids    = map { $_->id } @usergames;

    my $discard_rs = $schema->resultset('UserGameDiscard')->search(
        {
            user_game => { '-in' => \@ug_ids },
        }
    );

    my $count = $discard_rs->count;

    $discard_rs->delete if ($count);

    return $count
}

# Create a row in the "settings" table for a specified user, with default
# values.
#
# Arguments:
#
# - User Schema object.
#
# Returns:
#
# Setting Schema object.
sub db_create_usetting {
    my ($self, $user) = @_;

    my $schema = $self->_schema;

    debug("User %s doesn't have any settings; creating…", $user->nick);
    $schema->resultset('Setting')->create({ user => $user->id });

    # Refresh the relationship.
    $user->discard_changes;

    return $user->rel_setting;
}

# Send a message explaining there is no such game.
#
# Arguments:
#
# - Nick or channel to send the message to, as a scalar string.
#
# - Channel name the message relates to, as a scalar string.
#
# - Who to mention in the first line, or undef if no one.
#
# Returns:
#
# Nothing.
sub no_such_game {
    my ($self, $target, $chan, $mention);

    my $irc     = $self->_irc;
    my $my_nick = $irc->nick;

    if (defined $mention) {
        $irc->msg($target,
            "$mention: There's no game of Perpetually Against Humanity in"
           . " here.");
    } else {
        $irc->msg($target,
            "There's no game of Perpetually Against Humanity in $chan.");
    }

    $irc->msg($target,
        "Want to start one? Anyone with a registered nickname can do so.");

    if (defined $mention) {
        $irc->msg($target,
            qq{Just type "$my_nick: start" in the channel and find at least 3}
            . qq{ friends.});
    } else {
        $irc->msg($target,
            qq{Just type "$my_nick: start" in $chan and find at least 3}
            . qq{ friends.});
    }

    return;
}

# If the game has any users waiting to join it then deal them in now, as long
# as they are still in the channel.
#
# Arguments:
#
# - Game Schema object.
#
# Returns:
#
# Nothing.
sub dealin_waiters {
    my ($self, $game) = @_;

    my $irc = $self->_irc;

    my $player_count = $game->rel_active_usergames->count;
    my $channel      = $game->rel_channel;

    if ($player_count >= 20) {
        debug("There's users waiting to join the game at %s but it already has"
           . " %u players", $channel->disp_name, $player_count);
        return;
    }

    my $joinq = $self->_joinq;

    while (my $user = $joinq->pop($game)) {
        my $nick = do {
            if (defined $user->disp_nick) { $user->disp_nick }
            else                          { $user->nick }
        };

        debug("%s is waiting to join game in %s", $nick, $channel->disp_name);

        if (! $self->user_is_in_channel($user, $channel->disp_name)) {
            debug("%s isn't present in %s, so not adding", $nick,
                $channel->disp_name);
            next;
        }

        $self->add_user_to_game(
            {
                user => $user,
                game => $game,
            }
        );

        $irc->msg($channel->disp_name, "$nick: You're in now, too!");
    }
}

# Add the specified user to a game.
#
# Arguments:
#
# - A hash ref containing keys/vals:
#
#   - user => User Schema object.
#
#   - game => Game Schema object.
#
#   - tsar => 1 if the user is the new Card Tsar, 0 otherwise.
#
# Returns:
#
# The resulting UserGame Schema object.
sub add_user_to_game {
    my ($self, $args) = @_;

    foreach my $key (qw(user game)) {
        if (not defined $args->{$key}) {
            die "Argument $key must be supplied!";
        }
    }

    my $user    = $args->{user};
    my $game    = $args->{game};
    my $is_tsar = do {
        if (defined $args->{tsar} and 1 == $args->{tsar}) { 1 }
        else                                              { 0 }
    };

    my $schema = $self->_schema;

    my $channel = $game->rel_channel;

    my $who = do {
        if (defined $user->disp_nick) { $user->disp_nick }
        else                          { $user->nick }
    };

    my $usergame;

    if ($usergame = $self->user_is_in_game($user, $game)
            and 1 == $usergame->active) {
        debug("%s is somehow already participating in game at %s", $who,
            $channel->disp_name);
        return $usergame;
    }

    $usergame = $schema->resultset('UserGame')->update_or_create(
        {
            user          => $user->id,
            game          => $game->id,
            active        => 1,
            activity_time => time(),
        }
    );

    if ($is_tsar) {
        $usergame->is_tsar(1);

        if (defined $usergame->tsarcount) {
            $usergame->tsarcount($usergame->tsarcount + 1);
        } else {
            $usergame->tsarcount(1);
        }
    }

    # Update player activity timer.
    $usergame->activity_time(time());
    $usergame->update;

    debug("%s was added to game at %s%s", $who, $channel->disp_name,
        $is_tsar ? ' as Card Tsar' : '');

    return $usergame;
}

# Check whether a given User Schema object is present in a Game. If so return
# the UserGame Schema object. If not then return undef.
#
# Note that a User can be in a Game but not currently active.
#
# Arguments:
#
# - User Schema object.
#
# - Game Schema object.
#
# Returns:
#
# The corresponding UserGame Schema object, or undef.
sub user_is_in_game {
    my ($self, $user, $game) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('UserGame')->find(
        {
            user   => $user->id,
            game   => $game->id,
            active => 1,
        }
    );
}

# Is a User (Schema object) present in an IRC channel?
#
# Checks both the $user->nick and the $user->disp_nick if they are different.
#
# Arguments:
#
# - User Schema object.
#
# - IRC channel as a scalar string.
#
# Returns:
#
# 1 if present, undef otherwise.
sub user_is_in_channel {
    my ($self, $user, $chan) = @_;

    my $irc = $self->_irc;

    my $names = $irc->channel_list($chan);

    if (not defined $names) {
        debug("Tried to get a list of nicks in %s but got undef; am I even in"
           . " the channel?", $chan);
       return undef;
    }

    my %search;

    $search{lc($user->nick)} = 1;

    if (defined $user->disp_nick) {
        $search{lc($user->disp_nick)} = 1;
    }

    my %lc_names = map { lc($_) => $names->{$_} } keys %{ $names };

    foreach my $nick (keys %search) {
        if (exists $lc_names{$nick}) {
            # Found 'em.
            return 1;
        }
    }

    # Didn't find 'em.
    return undef;
}

# NickServ has just told us that we're identified to a nickname, so now we can
# do some things that require a registered nickname. So far this will be:
#
# - Ask ChanServ for voice in every channel we are currently in.
#
# Arguments:
#
# None.
#
# Returns:
#
# Nothing.
sub identified_to_nick {
    my ($self) = @_;

    my $irc = $self->_irc;

    my $my_nick = $irc->nick;

    my $list = $irc->channel_list;

    foreach my $chan (keys $list) {
        my $modes = $list->{$chan}->{$my_nick};

        if (defined $modes->{v}) {
            debug("I'm already voiced on $chan…");
        } else {
            debug("Asking for voice in %s…", $chan);
            $irc->msg("ChanServ", "voice $chan");
        }
    }
}

# Check if we're currently on our configured nickname, and if not then take
# steps to get it back.
#
# Arguments:
#
# None.
#
# Returns:
#
# 1 if we already had the correct nickname, 0 if steps had to be taken to
# recover it.
sub check_my_nick {
    my ($self) = @_;

    my $irc = $self->_irc;

    my $my_nick      = $irc->nick;
    my $desired_nick = $irc->{args}->{nick};

    if (lc($my_nick) eq lc($desired_nick)) {
        return 1;
    }

    # Just try to change to it. If we get a collision then on_irc_433 will
    # handle a GHOSTing for us.
    debug("Switching back to nick $desired_nick…");
    $irc->send_srv(NICK => $desired_nick);

    return 0;
}

# Periodic checks for sane state of the IRC connection such as:
#
# - Do I have my correct nickname?
#
# - Am I in all the channels I should be?
#
# Arguments:
#
# None.
#
# Returns:
#
# Nothing.
sub check_irc_sanity {
    my ($self) = @_;

    $self->check_my_nick;
    $self->join_welcoming_channels;
}

1;
