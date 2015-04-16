package PAH::Deck;
use YAML qw/LoadFile/;

# Attempt to load a YAML file that describes a pack of cards. For now will be
# found in packs/ and named $name.yml.
# TODO: Sanity check the structure of the pack.
sub new {
    my ($class, $packs) = @_;

    my $self = {
        _Black => [],
        _White => [],
        _packs => {},
    };

    my @packlist = split(/\s+/, $packs);

    my $i = 0;

    foreach my $name (@packlist) {
        my $yaml = LoadFile("./packs/$name.yml");

        # Trailing newlines begone.
        chomp(@{ $yaml->{Black} });
        chomp(@{ $yaml->{White} });

        push(@{ $self->{_Black} }, @{ $yaml->{Black} });
        push(@{ $self->{_White} }, @{ $yaml->{White} });

        my $pack = {
            name        => $name,
            order       => $i,
            description => $yaml->{Description},
            license     => $yaml->{License},
            copyright   => $yaml->{Copyright},
            counts      => {
                Black => scalar @{ $yaml->{Black} },
                White => scalar @{ $yaml->{White} },
            },
        };

        $self->{_packs}->{$name} = $pack;

        $i++;
    }

    bless $self, $class;

    return $self;
}

# Return an array of the packs currently in use.
#
# Arguments:
#
# None.
#
# Returns:
#
# Array of pack names as scalar strings.
sub packs {
    my ($self) = @_;

    my $packs = $self->{_packs};

    return map { $packs->{$_}->{name} }
           sort { $packs->{$a}->{order} <=> $packs->{$b}->{order} }
           keys %{ $packs };
}

# Return a list of strings describing the packs that have been loaded.
#
# Arguments:
#
# None.
#
# Returns:
#
# A list of scalar strings formatted like:
#
# name [Description of pack],
# other [Description of next pack],
# …
#
# Where "name" is the file name within the packs directory, without the .yaml
# suffix.
sub pack_descs {
    my ($self) = @_;

    my $packs = $self->{_packs};

    my @descs = map {
        $packs->{$_}->{name} . ' ['. $packs->{$_}->{description} . ']'
    } sort { $packs->{$a}->{order} <=> $packs->{$b}->{order} } keys %{ $packs };

    return @descs;
}

# Return the description for a particular pack name.
#
# Arguments:
#
# - Name of the pack as a scalar string. The name is the file name within the
#   "packs/" directory, without the ".yml" suffix.
#
# Returns:
#
# The description of the pack as a scalar string, or undef if the pack wasn't
# found.
sub pack_desc {
    my ($self, $name) = @_;

    if (not defined $name) {
        die "A pack name must be provided";
    }

    my $packs = $self->{_packs};

    if (defined $packs->{$name}) {
        return $packs->{$name}->{description};
    }

    return undef;
}

# Return a count of how many cards of a particular color are available in a
# particular card pack.
#
# Arguments:
#
# - Name of the pack as a scalar string. The name is the file name within the
#   "packs/" directory, without the ".yml" suffix.
#
# - Color of the card as a scalar string, so either 'Black' or 'White'.
#
# Returns:
#
# The count of the cards of the specified color, or undef if the card pack
# wasn't found.
sub pack_count {
    my ($self, $name, $color) = @_;

    if (not defined $name) {
        die "A pack name must be provided";
    }

    my $packs = $self->{_packs};

    if ($color ne 'Black' and $color ne 'White') {
        die "Card color must be either 'Black' or 'White'";
    }

    if (defined $packs->{$name}) {
        return $packs->{$name}->{counts}->{$color};
    }

    return undef;
}

# Return a count of how many cards are available in a particular color of deck.
#
# Arguments:
#
# - Color of deck as a scalar string, so either 'Black' or 'White'.
#
# Returns:
#
# How many cards there are.
sub count {
    my ($self, $color) = @_;

    if ($color ne 'Black' and $color ne 'White') {
        die "Deck color must be either 'Black' or 'White'";
    }

    my $deck = '_' . $color;

    return scalar @{ $self->{$deck} };
}

# Return the text of the given index of Black Card.
#
# Arguments:
#
# - Index into the Black deck as a 0-based integer.
#
# Returns:
#
# Text of the card as a scalar string.
sub black {
    my ($self, $index) = @_;

    return $self->_get_card('Black', $index);
}

# Return the text of the given index of White Card.
#
# Arguments:
#
# - Index into the White deck as a 0-based integer.
#
# Returns:
#
# Text of the card as a scalar string.
sub white {
    my ($self, $index) = @_;

    return $self->_get_card('White', $index);
}

# Return the text of the given index of card in the given color deck.
#
# Arguments:
#
# - Color of the deck as a scalar string, either 'Black' or 'White'.
#
# - Index into the deck as a 0-based integer.
#
# Returns:
#
# Text of the card as a scalar string.
sub _get_card {
    my ($self, $color, $index) = @_;

    if ($color ne 'Black' and $color ne 'White') {
        die "Deck color must be either 'Black' or 'White'";
    }

    my $deck = '_' . $color;

    return $self->{$deck}->[$index];
}

# Find the index of a card with the given text in the given color deck.
#
# Arguments:
#
# - Color of the deck as a scalar string, either 'Black' or 'White'.
#
# - Text of the card to find, as a scalar string.
#
# Returns:
#
# Index of the card as a scalar, or undef if not found.
sub find {
    my ($self, $color, $text) = @_;

    if ($color ne 'Black' and $color ne 'White') {
        die "Deck color must be either 'Black' or 'White'";
    }

    my $deck = '_' . $color;

    my $i = 0;

    foreach my $card (@{ $self->{$deck} }) {
        return $i if ($text eq $card);
        $i++;
    }

    return undef;
}

# Append a single new card to the deck of the given color.
#
# Arguments:
#
# - Color of the deck as a scalar string, either 'Black' or 'White'.
#
# - Text of the card to append, as a scalar string.
#
# Returns:
#
# Index of the card as a scalar.
sub append {
    my ($self, $color, $text) = @_;

    if ($color ne 'Black' and $color ne 'White') {
        die "Deck color must be either 'Black' or 'White'";
    }

    my $deck = '_' . $color;

    push(@{ $self->{$deck} }, $text);

    return scalar @{ $self->{$deck} } - 1;
}

1;
