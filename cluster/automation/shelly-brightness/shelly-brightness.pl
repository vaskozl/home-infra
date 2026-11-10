#!/usr/bin/perl
use v5.20;

use LWP::Simple;
use POSIX qw(strftime);

my $MAX = 80;
my $POW = 2;

# Non-dimmable: shellydimmer2-F4CFA2ECAE73
my @GEN1 = qw(
  shellydimmer2-3C6105E44BF8
  shellydimmer2-3C6105E42925
  shellydimmer2-3C6105E34976
);

# Gen2+ RPC API
my @GEN4 = qw(
  shellydimmerg4-acebe6e9c5b4
  shellydimmerg4-acebe6e72550
  shellydimmerg4-acebe6e90158
);

sub default_brightness {
  my $hour = strftime "%H", localtime;
  # Put max brightness at 2PM and min at 2AM
  $hour -= 2;
  $hour = 24 + $hour if $hour < 0;
  my $x = $MAX - $MAX*(abs($hour - 12)/12)**(1/$POW);
  say "The hour is $hour and the brightness will be $x";
  return int($x);
}

my $brightness = $ARGV[0] || default_brightness;

for my $shelly (@GEN1){
  get("http://$shelly.sko.ai/light/0?brightness=$brightness");
}

# Omitting "on" leaves the output state unchanged.
for my $shelly (@GEN4){
  get("http://$shelly.sko.ai/rpc/Light.Set?id=0&brightness=$brightness");
}
