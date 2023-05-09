#!/usr/bin/perl
use v5.20;

use LWP::Simple;
use POSIX qw(strftime);

my $MAX = 80;
my $POW = 2;

my @SHELLIES = qw(
shellydimmer2-3C6105E44BF8
shellydimmer2-3C6105E42925
shellydimmer2-3C6105E34976
shellydimmer2-84CCA8AD776A
shellydimmer2-F4CFA2ECDC0B
shellydimmer2-F4CFA2ECAE73
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

#say "Setting brightness to $brightness";
for my $shelly (@SHELLIES){
  get("http://$shelly.sko.ai/light/0?brightness=$brightness");
}
