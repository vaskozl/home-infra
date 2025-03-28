use warnings;

my $text = read;
my $chars = split('', $text);

my %counts = ();

for ($i = 0; $i < length($chars) - 1; $i++) {
    my $bigram = $chars[$i] . $chars[$i + 1];
    %counts{$bigram}++;
}

print "Number of unique bigrams: ", scalar(%counts), "\n";
