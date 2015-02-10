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

package PAH::Schema::Result::Game;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('games');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # Channel that this game is/was taking place in.
    channel => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # unixstamp of when the game was created.
    create_time => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # unixstamp of when the last activity took place.
    activity_time => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Status of this game.
    #
    # 0: Paused for unknown reason.
    # 1: Paused while gathering players.
    # 2: Playing.
    status => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('games_channel_idx' => ['channel']);

# Relationships.

# A Game always has a Channel.
__PACKAGE__->belongs_to(
    rel_channel => 'PAH::Schema::Result::Channel', 
    { 'foreign.id' => 'self.channel' }
);

# A Game has zero or more UserGames
__PACKAGE__->has_many(
    rel_usergames => 'PAH::Schema::Result::UserGame', 
    { 'foreign.game' => 'self.id' }
);

# On deploy add some indexes.
sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(
        name   => 'games_status_idx',
        fields => ['status']
    );
}

1;
