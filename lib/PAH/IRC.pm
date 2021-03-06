# © 2010 David Leadbeater; https://dgl.cx/licence
# © 2015 Andy Smith <andy-pah-irc@strugglers.net>

package PAH::IRC;
use utf8;
use EV; # AnyEvent::Impl::Perl seems to behave oddly
use strict;

use constant DEBUG => $ENV{IRC_DEBUG};

=head1 NAME

PAH::IRC - Lame wrapper around AnyEvent::IRC::Client for pah-irc

=cut

use base "AnyEvent::IRC::Client";
use AnyEvent::IRC::Util qw(prefix_nick);
use JSON::MaybeXS qw(to_json);
use Encode;
use Algorithm::TokenBucket;

use PAH::Log;

use Data::Dumper;

sub connect {
    my($self, $parent, $addr, $port, $args) = @_;

    ($self->{pah_connect_cb} = sub {
            $self->SUPER::connect($addr, $port, $args);

            $self->{parent} = $parent;
            $self->{args} = $args;

            $EV::DIED = sub {
                warn "Caught exception, will continue: $@";
            };

            $SIG{__WARN__} = sub {
                warn @_;
            };

        }
    )->();

    $self->reg_cb(debug_cb => sub {
            debug "@_";
        }
    );

  # Register our callbacks
  for (qw(
      registered
      connect
      disconnect
      join
      irc_433
      irc_notice
      irc_invite
      kick
      publicmsg
      privatemsg
      irc_318
      irc_330
      irc_401
      )
  ) {
      my $callback = "on_$_";

      $self->reg_cb($_ => sub {
              my $irc = shift;
              my $json = (ref($_[0]) eq 'HASH' ? to_json($_[0]) : "");

              debug("IRC: $callback: $json") if DEBUG;
              $self->$callback(@_);
          }
      );
  }

}

# Don't send the IRC PRIVMSG right away, as this game is quite wordy and can
# easily lead to excess flood kills from the IRC server.
#
# Instead use an incredibly dumb throttling mechanism: a simple list to which
# messages are appended and consumed from the back once per second.
sub msg {
    my ($self, $who, $text) = @_;

    my $queue = $self->{_msg_queue};

    my $item = {
        who  => $who,
        text => $text,
    };

    push @{ $queue }, $item;
}

sub notice {
    my ($self, $who, $text) = @_;
    $self->send_srv(NOTICE => $who, $text);
}

sub on_registered {
    my ($self) = @_;

    $self->enable_ping(90);

    # But do we have our proper nickname?
    $self->{parent}->check_my_nick;

    $self->{_msg_queue} = [ ];

    $self->{msg_timer} = AnyEvent->timer(
        after    => 0,
        interval => 0.2,
        cb => sub {
            $self->process_msg_queue();
        },
    );

    $self->{waitclock_timer} = AnyEvent->timer(
        after    => 60,
        interval => 60,
        cb       => sub {
            $self->{parent}->check_idlers($self->{parent}->_config->{turnclock});
        },
    );

    $self->{parent}->join_welcoming_channels;

    # Do sanity checks like do I have my nick, am I in the right channels etc.
    $self->{sanity_timer} = AnyEvent->timer(
        after    => 60,
        interval => 300,
        cb       => sub {
            $self->{parent}->check_irc_sanity;
        },
    );
}

# If there are IRC messages in the send queue and the token bucket says we can
# send, take the oldest one and send it.
#
# TODO: Experiment with what is actually a safe interval. 1/sec is quite slow.
# TODO: Consider using the send queue for more than just PRIVMSG?
sub process_msg_queue {
    my ($self) = @_;

    my $queue = $self->{_msg_queue};

    if (scalar @{ $queue }) {
        if (not defined $self->{_bucket}) {
            debug("Creating token bucket, %.2f per sec, burst %u",
                $self->{parent}->_config->{msg_per_sec},
                $self->{parent}->_config->{msg_burst});
            $self->{_bucket} = Algorithm::TokenBucket->new(
                $self->{parent}->_config->{msg_per_sec},
                $self->{parent}->_config->{msg_burst});
        }

        my $bucket = $self->{_bucket};

        if (not $bucket->conform(1)) {
=pod
            debug("Delaying sending a PRIVMSG because the token bucket is empty:");
            debug("  %s → %s", $queue->[0]->{text}, $queue->[0]->{who});
=cut
            return;
        }

        my $first = undef;
        my $index = 0;

        foreach my $msg (@{ $queue }) {
            if ($msg->{who} =~ /^[#\&]/) {
                # Message is to a channel, so send it first.
                $first = $msg;
                splice @{ $queue }, $index, 1;
                last;
            }

            $index++;
        }

        if (not defined $first) {
            # Found no messages for channels, so just take off first private message.
            $first = shift @{ $queue };
        }

        $self->send_srv(PRIVMSG => $first->{who}, encode('utf-8', $first->{text}));
        $bucket->count(1);
    }
}

sub on_connect {
    my ($self, $error) = @_;

    if ($error) {
        warn "Unable to connect: $error\n";
        $self->on_disconnect;
    }
}

sub on_disconnect {
    my ($self) = @_;

    $self->{reconnect_timer} = AE::timer 10, 0, sub {
        undef $self->{reconnect_timer};
        $self->{pah_connect_cb}->();
    };
}

sub on_join {
    my ($self, $nick, $channel, $myself) = @_;

    if ($myself) {
        $self->{parent}->joined($channel);
        return;
    }

    # It's not us. Decide about introducing them to the game.
    $self->{parent}->user_joined($channel, $nick);
}

sub on_kick {
    my ($self, $kicked_nick, $channel, $myself, $msg, $kicker) = @_;

    # $myself doesn't appear to ever be set so will have to check if it is us
    # that was kicked another way.
    return unless $self->is_my_nick($kicked_nick);

    debug("Kicked from %s by %s: %s", $channel, $kicker, $msg);

    $self->notice($kicker, "Sorry if I upset anyone! I'll stay out of"
       . " $channel in future, unless invited back.");

    $self->{parent}->mark_unwelcome($channel);
}

# Nick in use
sub on_irc_433 {
    my ($self) = @_;

    # We don't have our nick then. Try a NickServ GHOST command.
    debug("Issuing NickServ GHOST command to get my nickname back");
    $self->send_srv(
        NickServ => "GHOST $self->{args}->{nick} $self->{args}->{nick_pass}"
    );

    # NickServ should send us a NOTICE saying the interloper was GHOSTed, at
    # which point we'll switch nicks.
}

sub on_irc_notice {
    my($self, $msg) = @_;

    if(lc prefix_nick($msg) eq 'nickserv') {
        local $_ = $msg->{params}->[-1];

        if (/This nick is owned by someone else/ ||
            /This nickname is registered/i) {
            debug("ID to NickServ at request of NickServ");
            $self->msg("NickServ", "IDENTIFY $self->{args}->{nick_pass}");

        } elsif (/(\S+) has been ghosted\.$/i) {
            my $their_nick = $1;

            debug("NickServ told me that someone using my nick %s got ghosted."
               . " Getting it back now!", $their_nick);
            $self->send_srv(NICK => $self->{args}->{nick});

        } elsif (/Your nick has been recovered/i) {
            debug("NickServ told me I recovered my nick, RELEASE'ing now");
            $self->msg("NickServ",
                "RELEASE $self->{args}->{nick} $self->{args}->{nick_pass}");

        } elsif (/Your nick has been released from custody/i) {
            debug("NickServ told me my nick is released, /nick'ing now");
            $self->send_srv(NICK => $self->{args}->{nick});
        } elsif (/You are now identified for/i) {
            debug("NickServ told me I was identified for a nickname");
            $self->{parent}->identified_to_nick;
            # Make sure we are in the right channels (may be some that we
            # needed to be identified to get in to).
            $self->{parent}->join_welcoming_channels;
        } else {
            debug("Ignoring NickServ notice: %s", $_);
        }
    }
}

sub on_irc_invite {
    my ($self, $arg) = @_;

    my $chan = $arg->{params}->[1];
    my $inviter = $arg->{prefix};

    debug("Invited to %s by %s; marking welcome", $chan, $inviter);
    $self->{parent}->create_welcome($chan);
    debug("And now joining %s", $chan);
    $self->send_srv(JOIN => $chan);
}

sub on_publicmsg {
    my ($self, $channel, $ircmsg) = @_;

    # Ignore public stuff that isn't a normal message.
    if ($ircmsg->{command} !~ /^PRIVMSG$/i) {
        debug("Ignoring a NOTICE to %s…", $channel);
        return;
    }

    my $nick    = $self->nick;
    my $from    = (split(/!/, $ircmsg->{prefix}))[0];
    my $content = $ircmsg->{params}->[1];

    # Only interested in public messages that start with our nickname and an
    # optional separator, e.g.:
    #
    # AgainstHumanity status
    # AgainstHumanity, status
    # AgainstHumanity: status
    if ($content !~ /^$nick\s*(?:[,;:]\s*)?(.*)$/i) {
        # Whatever they said isn't a command, so is porbably just normal
        # chatter. Check if we are waiting on them to perform some action and
        # poke them to do it if so.
        $self->{parent}->poke($from, $channel);
        return;
    }

    my $for_us = $1;
    debug("<%s:%s> %s", $from, $channel, $content);

    $self->{parent}->process_chan_command($from, $channel, $for_us);
}

sub on_privatemsg {
    my ($self, $me, $ircmsg) = @_;

    my $from    = (split(/!/, $ircmsg->{prefix}))[0];
    my $content = $ircmsg->{params}->[1];

    # Ignore stuff that isn't a normal message.
    if ($ircmsg->{command} !~ /^PRIVMSG$/i) {
        return;
    }

    debug("<%s> %s", $from, $content);

    $self->{parent}->process_priv_command($from, $content);
}

# This is the "is logged in as" WHOIS reply. If we get it then it tells us
# which services account the nickname is identified as, so once it's received
# we can go through the WHOIS callback queue and execute every callback.
sub on_irc_330 {
    my ($self, $args) = @_;

    my $who         = lc($args->{params}->[1]);
    my $account     = lc($args->{params}->[2]);
    my $whois_queue = $self->{parent}->_whois_queue;

    debug("%s logged in as %s", $who, $account);

    return unless (defined $whois_queue);

    # WHOIS queue for this nickname.
    my $queue = $whois_queue->{$who};

    my $item;

    if (defined $account) {
        debug("WHOIS confirms that %s is logged in as %s", $who, $account);

        # We now need to go through the callback queue and find every callback
        # waiting for the nickname $who.
        while ($item = pop(@{ $queue })) {
            $self->{parent}->execute_whois_callback($item);
        }
    }
}

# This is the "End of WHOIS" WHOIS reply. Once this is recevied there isn't
# going to be any more WHOIS info, so anything left on the WHOIS callback queue
# can be sent an error message.
sub on_irc_318 {
    my ($self, $args) = @_;

    my $who         = lc($args->{params}->[1]);
    my $whois_queue = $self->{parent}->_whois_queue;

    return unless (defined $whois_queue);

    # WHOIS queue for this nickname.
    my $queue = $whois_queue->{$who};

    my $item;

    while ($item = pop(@{ $queue })) {
        $self->{parent}->denied_whois_callback($item);
    }
}

# This is the "No such nick" reply. If we get one then we were trying to talk
# to someone who is no longer here. We'll try to work out which games they were
# active in and inform those games about what is going on.
sub on_irc_401 {
    my ($self, $args) = @_;

    my $who  = $args->{params}->[1];
    my $user = $self->{parent}->db_get_user($who);

    debug("Received a No such nick for %s", $who);

    foreach my $ug ($user->rel_active_usergames) {
        debug("…%s active in game at %s", $who,
            $ug->rel_game->rel_channel->disp_name);

        # How long ago did we last tell the channel about this?
        my $now  = time();
        my $game = $ug->rel_game;
        my $chan = $game->rel_channel;
        my $last = $self->{parent}->_last;

        if (defined $game and defined $last and defined $last->{$game->id}
                and defined $last->{$game->id}->{$user->id}
                and defined $last->{$game->id}->{$user->id}->{nsn}) {
            my $last_nsn = $last->{$game->id}->{$user->id}->{nsn};

            if (($now - $last_nsn) <= (60 * 60)) {
                # Last time we did a no such nick for this user in this game
                # was an hour or less ago.
                debug("…Not doing anything about No such nick for %s in game at"
                   . " %s as it was already notified %u secs ago", $who,
                   $chan->disp_name, $now - $last_nsn);
                next;
            }
        }

        if (defined $game and 2 == $game->status) {
            # Record timestamp of when we did this.
            $last->{$game->id}->{$user->id}->{nsn} = $now;

            # And now tell the channel.
            $self->msg($chan->disp_name,
                "I can't see $who on this IRC network. If anyone knows where"
               . " they are please ask them to come back, otherwise we wait"
               . " until the clock runs out.");
        }
    }

}

sub on_debug_recv {
    my $self = shift;
    print STDERR Dumper(\@_);
}

1;
