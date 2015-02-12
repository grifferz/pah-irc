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

package PAH::Schema::Result::WCard;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('wcards');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # Game that this card belongs to.
    game => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Index within the White Card array of this card (zero-based).
    cardidx => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships.

# A WCard always has a Game.
__PACKAGE__->belongs_to(
    rel_game => 'PAH::Schema::Result::Game',
    { 'foreign.id' => 'self.game' }
);

1;
