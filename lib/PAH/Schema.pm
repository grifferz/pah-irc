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

package PAH::Schema;
use base qw/DBIx::Class::Schema/;

use warnings;
use strict;
our $VERSION = '0.0013';

use PAH::UnicornLogger;
my $pp = PAH::UnicornLogger->new(
    {
        tree             => { profile => 'console' },
        profile          => 'console',
        format           => '%d ** %m',
        multiline_format => '   %m',
    }
);

sub connection {
    my $self = shift;

    my $ret = $self->next::method(@_);

    $self->storage->debugobj($pp);

    $ret
};

__PACKAGE__->load_namespaces();

__PACKAGE__->load_components(qw/Schema::Versioned/);

1;
