#!/usr/bin/env perl

# vim:set sw=4 cindent:

=encoding utf8
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

use warnings;
use strict;
use Config;
use FindBin;
use lib "lib", map "pah-libs/lib/perl5/$_", "", $Config{archname};

BEGIN {
  chdir "$FindBin::Bin/..";
}

use PAH;

my $pah = PAH->new_with_options;

$SIG{HUP} = sub {
  $pah->handle_sighup;
};

$SIG{TERM} = $SIG{INT} = sub {
  $pah->shutdown;
  exit 0;
};

STDOUT->autoflush(1);
STDERR->autoflush(1);

$pah->start;
