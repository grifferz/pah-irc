package PAH::Deck;
use YAML qw/LoadFile/;

use parent "Exporter";
our @EXPORT = qw/pack_descs black white/;

# Attempt to load a YAML file that describes a pack of cards. For now will be
# found in packs/ and named $name.yml.
# TODO: Support multiple packs (issue #75).
# TODO: Sanity check the structure of the pack.
sub new {
    my ($class, $packs) = @_;

    my $self = {
        _Black => [],
        _White => [],
        _packs => [],
    };

    my @packlist = split("\s+", $packs);

    if (scalar @packlist != 1) {
        die "Multiple packs not supported yet";
    }

    my $name = $packlist[0];

    my $yaml = LoadFile("./packs/$name.yml");

    push(@{ $self->{_Black} }, @{ $yaml->{Black} });
    push(@{ $self->{_White} }, @{ $yaml->{White} });

    my $pack = {
        name        => $name,
        description => $yaml->{Description},
        license     => $yaml->{License},
        copyright   => $yaml->{Copyright},
    };

    push(@{ $self->{_packs} }, $pack);

    bless $self, $class;

    return $self;
}

# Return a string describing the packs that have been loaded.
#
# Arguments:
#
# None.
#
# Returns:
#
# A scalar string formatted like:
#
# name [Description of pack] other [Description of next pack] …
#
# Where "name" is the file name within the packs directory, without the .yaml
# suffix.
sub pack_descs {
    my ($self) = @_;

    my $string;

    foreach my $pack (@{ $self->{_packs} }) {
        $string .= $pack->{name} . ' [' . $pack->{description} . '] ';
    }

    $string =~ s/\s+$//;

    return $string;
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
# Return:
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

1;
