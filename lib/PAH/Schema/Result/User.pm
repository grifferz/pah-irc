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

package PAH::Schema::Result::User;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('users');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # Nickname of this user. Will be stored downcased.
    nick => {
        data_type   => 'varchar',
        is_nullable => 0,
        size        => 50, # Max length of Freenode nick
    },

);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('users_nick_idx' => ['nick']);

# Relationships.

# A User has zero or more UserGames
__PACKAGE__->has_many(
    rel_usergames => 'PAH::Schema::Result::UserGame', 
    { 'foreign.user' => 'self.id' }
);

# A User has zero or more active UserGames
__PACKAGE__->has_many(
    rel_active_usergames => 'PAH::Schema::Result::UserGame',
    { 'foreign.user'   => 'self.id' },
    { where => { 'active' => 1 } }
);

1;
