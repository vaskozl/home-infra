#!/usr/bin/perl
use strict;
use warnings;

use feature qw(say);

use YAML::XS qw(LoadFile Dump);
use Scalar::Util qw(openhandle);

my $h = LoadFile($ARGV[0]);
my $name = $h->{metadata}{name};

my $o = $h->{spec}{values};

my $ingress = delete $o->{ingress};
my $host = shift @{$ingress->{app}{hosts}};

$o->{route} = {
  app => {
    hostnames => [$host->{host}],
    parentRefs => [
      {
        name => 'ts-internal',
        namespace => 'envoy',
      },
    ],
  }
};

$o->{route}{app}{annotations} = $ingress->{app}{annotations} if $ingress->{app}{annotations};

if ($ARGV[1] eq 'write') {
  DumpFile($ARGV[0], $h);
  exec "yamlfmt", $ARGV[0];
} else {
  print Dump $h;
}


sub DumpFile {
    my $OUT;
    my $filename = shift;
    if (openhandle $filename) {
        $OUT = $filename;
    }
    else {
        my $mode = '>';
        if ($filename =~ /^\s*(>{1,2})\s*(.*)$/) {
            ($mode, $filename) = ($1, $2);
        }
        open $OUT, $mode, $filename
          or die "Can't open '$filename' for output:\n$!";
    }
    local $/ = "\n"; # reset special to "sane"
    print $OUT '# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json' . "\n";
    print $OUT YAML::XS::LibYAML::Dump(@_);
}
