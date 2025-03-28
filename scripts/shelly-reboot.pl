#!/usr/bin/perl
use v5.20;

use LWP::Simple;

my @SHELLIES = qw(
  shellydimmer2-3C6105E44BF8
  shellydimmer2-3C6105E42925
  shellydimmer2-3C6105E34976
  shellydimmer2-84CCA8AD776A
  shellydimmer2-F4CFA2ECDC0B
  shellydimmer2-F4CFA2ECAE73
  shelly1-40f5201cddb9
);

for my $shelly (@SHELLIES){
  get("http://$shelly.sko.ai/reboot");
}
