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

package PAH::Schema::Result::Channel;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('channels');

__PACKAGE__->add_columns(

    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
        extra             => { unsigned => 1 },
    },

    # Name of the channel including the initial sigil (usually '#').
    # This is downcased and suitable for comparisons.
    name => {
        data_type   => 'varchar',
        size        => 50, # Max length of Freenode channel
        is_nullable => 0,
    },

    # Name of the channel including the initial sigil (usually '#').
    # This is the original case as seen in the initial invite command, which
    # may be mixed case. It will be used in conversational messages but not
    # commands.
    disp_name => {
        data_type   => 'varchar',
        size        => 50, # Max length of Freenode channel
        is_nullable => 0,
    },

    # Are we welcome in this channel?
    #
    # 0: No
    # 1: Yes
    #
    # If we are kicked out of a channel we were previously operating in then
    # we'd become unwelcome until invited again.
    welcome => {
        data_type     => 'integer',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },

);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('channels_name_idx' => ['name']);
__PACKAGE__->add_unique_constraint('channels_disp_name_idx' => ['disp_name']);

# Relationships.

# A Channel might have a Game.
__PACKAGE__->might_have(
    rel_game => 'PAH::Schema::Result::Game',
    { 'foreign.channel' => 'self.id' }
);

# On deploy add some indexes.
sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(
        name   => 'channels_welcome_idx',
        fields => ['welcome']
    );
}

1;
