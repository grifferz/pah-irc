package PAH::Deck;
use YAML qw/LoadFile/;

use parent "Exporter";
our @EXPORT = qw/pack_descs packs black white append find/;

# Attempt to load a YAML file that describes a pack of cards. For now will be
# found in packs/ and named $name.yml.
# TODO: Sanity check the structure of the pack.
sub new {
    my ($class, $packs) = @_;

    my $self = {
        _Black => [],
        _White => [],
        _packs => [],
    };

    my @packlist = split(/\s+/, $packs);

    foreach my $name (@packlist) {
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

    return map { $_->{name} } @{ $self->{_packs} };
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

    my @descs = map {
        $_->{name} . ' ['. $_->{description} . ']'
    } @{ $self->{_packs} };

    return @descs;
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
