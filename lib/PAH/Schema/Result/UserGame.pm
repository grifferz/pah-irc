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

package PAH::Schema::Result::UserGame;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('users_games');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # User playing this Game.
    user => {
        data_type => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Game this User is in.
    game => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Awesome Points (wins).
    wins => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 0,
    },

    # Hands played in this game.
    hands => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 0,
    },

    # Number of times this user was Card Tsar.
    tsarcount => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 0,
    },

    # Is this user the Card Tsar in the current hand?
    #
    # 0: No.
    # 1: Yes.
    is_tsar => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 0,
    },

    # Waiting on a move since timestamp.
    wait_since => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 0,
    },

    # Is the User active in this Game?
    #
    # 0: No.
    # 1: Yes.
    active => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 1,
    },

);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(
    'users_games_user_game_idx' => [
        'user',
        'game',
    ]
);

# Relationships.

# A UserGame always has a User.
__PACKAGE__->belongs_to(
    rel_user => 'PAH::Schema::Result::User', 
    { 'foreign.id' => 'self.user' }
);

# A UserGame always has a Game.
__PACKAGE__->belongs_to(
    rel_game => 'PAH::Schema::Result::Game', 
    { 'foreign.id' => 'self.game' }
);

1;
