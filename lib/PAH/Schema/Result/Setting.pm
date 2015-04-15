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

package PAH::Schema::Result::Setting;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('settings');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # User these settings are for.
    user => {
        data_type   => 'integer',
        is_nullable => 0,
        extra       => { unsigned => 1 },
    },

    # Possessive pronoun that the bot will use when referring to this user's
    # plays, wins, etc.
    # http://en.wikipedia.org/wiki/Gender-specific_and_gender-neutral_pronouns#Summary
    #
    # If set, this is the pronoun. If NULL, the default pronoun "their" will be
    # used.
    pronoun => {
        data_type     => 'varchar',
        is_nullable   => 1,
        size          => 5,
        default_value => NULL,
    },

    # Whether User wants to be poked when the bot sees them chat. Defaults to 1
    # (yes).
    chatpoke => {
        data_type     => 'integer',
        is_nullable   => 0,
        extra         => { unsigned => 1 },
        default_value => 1,
    },

);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('settings_user_idx' => ['user']);

# Relationships.

# A Setting always has a User.
__PACKAGE__->belongs_to(
    rel_user => 'PAH::Schema::Result::User',
    { 'foreign.id' => 'self.user' }
);

1;
