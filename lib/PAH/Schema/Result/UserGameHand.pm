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

package PAH::Schema::Result::UserGameHand;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('users_games_hands');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # UserGame this relates to.
    user_game => {
        data_type => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Index into White Card list this relates to.
    wcardidx => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(
    'users_games_hands_user_game_wcardidx_idx' => [
        'user_game',
        'wcardidx',
    ]
);

# Relationships.

# A UserGameHand always has a UserGame.
__PACKAGE__->belongs_to(
    rel_usergame => 'PAH::Schema::Result::UserGame',
    { 'foreign.id' => 'self.user_game' }
);

1;
