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

package PAH::UnicornLogger;
use base qw/DBIx::Class::UnicornLogger/;

use warnings;
use strict;

sub query_start {
    my $self = shift;

    my $i = 0;
    my @caller;
    my @parent;

    while (@caller = caller($i)) {
        if ($caller[1] =~ m#^lib/#) {
            @parent = caller($i + 1);
            last;
        }

        $i++;
    }

    if (scalar @caller) {
        $self->print(
            sprintf("%s %s:%u", $parent[3], $caller[1], $caller[2]));
    }

    $self->SUPER::query_start(@_);
}

1;
