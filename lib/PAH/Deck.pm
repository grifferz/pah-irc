package PAH::Deck;
use YAML qw/LoadFile/;

use parent "Exporter";
our @EXPORT = qw(load);

# Attempt to load a YAML file that describes a deck of cards. For now will be
# found in decks/ and name $name.yml.
# TODO: Sanity check the structure of the deck.
sub load {
    my ($self, $name) = @_;

    my $deck->{$name} = LoadFile("./decks/$name.yml");

    return $deck;
}

1;
