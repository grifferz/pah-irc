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
      irc_318
      irc_330
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

    $self->{_msg_queue} = [ ];

    $self->{msg_timer} = AnyEvent->timer(
        after => 0,
        interval => 1,
        cb => sub {
            $self->process_msg_queue();
        },
    );

    $self->{parent}->join_welcoming_channels;
}

# If there are IRC messages in the send queue, take the oldest one and send it.
#
# This is very dumb and operates on a fixed interval of 1 per second.
#
# TODO: Make it smarter, e.g. allowing for bursts, use token bucket filter, etc.
# TODO: Experiment with what is actually a safe interval. 1/sec is quite slow.
# TODO: Consider using the send queue for more than just PRIVMSG?
sub process_msg_queue {
    my ($self) = @_;

    my $queue = $self->{_msg_queue};

    if (scalar @{ $queue }) {
        my $first = shift @{ $queue };

        $self->send_srv(PRIVMSG => $first->{who}, $first->{text});
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

    $self->{parent}->joined($channel) if $myself;
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

  $self->send_srv(NICK => $self->{nick} . $$);
  $self->msg("NickServ",
      "RECOVER $self->{args}->{nick} $self->{args}->{nick_pass}");
}

sub on_irc_notice {
  my($self, $msg) = @_;

  if(lc prefix_nick($msg) eq 'nickserv') {
    local $_ = $msg->{params}->[-1];

    if (/This nick is owned by someone else/ ||
        /This nickname is registered/i) {
      debug("ID to NickServ at request of NickServ");
      $self->msg("NickServ", "IDENTIFY $self->{args}->{nick_pass}");

    } elsif (/Your nick has been recovered/i) {
      debug("NickServ told me I recovered my nick, RELEASE'ing now");
      $self->msg("NickServ", "RELEASE $self->{args}->{nick} $self->{args}->{nick_pass}");

    } elsif (/Your nick has been released from custody/i) {
      debug("NickServ told me my nick is released, /nick'ing now");
      $self->send_srv(NICK => $self->{args}->{nick});
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
        debug("Ignoring irrelevant msg to %s…", $channel);
        return;
    }

    my $for_us = $1;
    debug("<%s:%s> %s", $from, $channel, $content);

    $self->{parent}->process_chan_command($from, $channel, $for_us);
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

sub on_debug_recv {
    my $self = shift;
#    print STDERR Dumper(\@_);
}

1;
