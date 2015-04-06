package PAH::Dispatch;

=pod
Build a dispatch table of command names that will call subroutines.

Each command can be marked as being privileged or not.

Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

Artistic license same as Perl.
=cut

use utf8;

use Carp qw/croak/;

# Create a new dispatch table.
#
# Internal implementation is a hashref of hashrefs.
#
# Arguments:
#
# None.
sub new {
    my ($class) = @_;

    my $self = {
        _table => {},
    };

    bless $self, $class;

    return $self;
}

# Add a new command to the dispatch table.
#
# Arguments:
#
# - Command name as scalar string.
#
# - A reference to a subroutine that will be called.
#
# - A scalar indicating whether the command is privileged or not; false (or
#   undef) for no, true for yes.
sub add_cmd {
    my ($self, $cmd, $sub, $priv) = @_;

    if (not defined $cmd) {
        croak "Command name must be supplied.";
    }

    if (not defined $sub) {
        croak "A reference to a subroutine must be supplied.";
    }

    if (ref($sub) ne 'CODE') {
        croak "Expected a reference to a subroutine.";
    }

    if (not defined $priv) {
        $priv = 0;
    }

    $priv = 1 if ($priv);

    my $table = $self->{_table};

    if ($self->cmd_exists($cmd)) {
        croak "Command '$cmd' already exists in dispatch table.";
    }

    $priv = 0 if (not defined $priv);

    $table->{$cmd} = {
        sub        => $sub,
        privileged => $priv,
    }
}

# Check if a command already exists in the dispatch table.
#
# Arguments:
#
# - Command name to check as a scalar string.
#
# Returns:
#
# True if the command exists, false otherwise.
sub cmd_exists {
    my ($self, $cmd) = @_;

    return exists $self->{_table}->{$cmd};
}

# Check if a command is privileged or not.
#
# Arguments:
#
# - Command name to check as a scalar string.
#
# Returns:
#
# True if the command is privileged, false otherwise.
sub is_privileged {
    my ($self, $cmd) = @_;

    if (not $self->cmd_exists($cmd)) {
        croak "Command '$cmd' doesn't exist.";
    }

    # Force it to be true or false.
    return !! $self->{_table}->{$cmd}->{privileged};
}

# Get the subroutine reference for a command.
#
# Arguments:
#
# - Command name to check as a scalar string.
#
# Returns:
#
# The subroutine reference.
sub get_cmd {
    my ($self, $cmd) = @_;

    if (not $self->cmd_exists($cmd)) {
        croak "Command '$cmd' doesn't exist.";
    }

    return $self->{_table}->{$cmd}->{sub};
}

1;
