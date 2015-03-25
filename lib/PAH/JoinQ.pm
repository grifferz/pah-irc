package PAH::JoinQ;

=pod
Maintain a queue of users who wish to join games but can't yet for some reason.

Current design is a hash of iterators, one per Game id, which will return the
next User who wants to join, or undef when there are no more.

The iterator is currently provided by DBIx::Class as a ResultSet (the
$rs->next() interface).

Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

Artistic license same as Perl.
=cut

use Carp qw/croak/;

sub new {
    my ($class, $schema) = @_;

    if (not defined $schema) {
        die "schema argument must be provided!";
    }

    my $self = {
        _schema => $schema,
        _iter   => {},
    };

    bless $self, $class;

    return $self;
}

# Add a new user to the join queue for a game.
#
# Arguments:
#
# - Hash ref containing the following keys/values:
#
#   - user => User Schema object.
#
#   - game => Game Schema object.
#
# Returns:
#
# The Waiter schema object which was created.
sub push {
    my ($self, $args) = @_;

    foreach my $key (qw(user game)) {
        if (not defined $args->{$key}) {
            croak "No $key argument provided";
        }
    }

    my $user = $args->{user};
    my $game = $args->{game};

    my $schema = $self->{_schema};

    my $waiter = $schema->resultset('Waiter')->update_or_create(
        {
            user       => $user->id,
            game       => $game->id,
            wait_since => time(),
        }
    );

    return $waiter;
}

# Return a single User Schema object for a user that is waiting to join a game,
# or undef if there are no users left waiting. The relevant Waiter row is
# deleted.
#
# Arguments:
#
# - Game Schema object that users are waiting on.
#
# Returns:
#
# User Schema object or undef if there's no users waiting.
sub pop {
    my ($self, $game) = @_;

    if (not defined $game) {
        croak "A game argument is required!";
    }

    my $schema = $self->{_schema};

    if (not defined $self->{_iter}->{$game->id}) {
        $self->{_iter}->{$game->id} = _make_iterator($schema, $game);
    }

    my $iter = $self->{_iter}->{$game->id};

    if (my $waiter = $iter->next) {
        my $user = $waiter->rel_user;

        # Delete the Waiter.
        $waiter->delete;

        # And give the User back.
        return $user;
    }

    # Delete the iterator so it can pick up more waiters in future with a new
    # query.
    delete $self->{_iter}->{$game->id};

    return undef;
}

# Generate an iterator function that keeps returning matching rows from the
# waiters table until there's none left.
#
# Arguments:
#
# - Schema object.
#
# - Game Schema object this will be an interator for.
#
# Returns:
#
# - Iterator function that will return the next row from the waiters table.
sub _make_iterator {
    my ($schema, $game) = @_;

    return $schema->resultset('Waiter')->search(
        {
            game => $game->id,
        },
        {
            order_by => 'wait_since ASC',
            prefetch => 'rel_user',
        }
    );
}

1;
