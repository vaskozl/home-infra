#!/usr/bin/perl
use strict;
use warnings;

use JSON::XS qw(decode_json encode_json);
use MIME::Lite;
use Mojo::UserAgent;
use Mojo::Util qw(getopt dumper);
use Path::Tiny;

use constant ARCH_SECURITY => 'https://security.archlinux.org/issues/all.json';
use constant IMAGE_FILTER  => qr{ghcr[.]io/vaskozl};
use constant SA_TOKEN      => '/var/run/secrets/kubernetes.io/serviceaccount/token';
use constant SBOM_PATH     => '/var/lib/db/sbom';

getopt
  'u|upgradable' => \my $upgradeable,
  'm|mailto=s'   => \my $mail_to,
  'f|from=s'     => \my $mail_from,
  's|server=s'   => \my $mail_server,
  'v|verbose'    => \my $verbose;

my $ua = Mojo::UserAgent->new->insecure(1);
my $token = path(SA_TOKEN)->slurp;
my $k8s_api = 'https://kubernetes.default.svc.cluster.local';
my $affected_ctr_limit = 5;

sub _k8s_headers { { 'Authorization' => "Bearer $token", 'Accept' => 'application/json' } }

sub _installed_packages {
  my $pod_data = $ua->get($k8s_api .
    '/api/v1/pods?fieldSelector=status.phase=Running',
    _k8s_headers
  )->result->json;

  my %pacman_q;
  my %spdx;
  my %processed_images;
  for my $pod (@{$pod_data->{items}}) {
      my $namespace = $pod->{metadata}{namespace};
      my $pod_name = $pod->{metadata}{name};

      # Get the list of containers in the pod
      my @containers = @{$pod->{spec}{containers}};

      for my $container (@containers) {
          my $container_name = $container->{name};
          my $container_image = $container->{image};
          next if $pacman_q{$container_image};

          # Check if the image name contains "vaskozl"
          if ($container_image && $container_image =~ IMAGE_FILTER) {
            print "Extracting sbom of $container_image\n" if $verbose;
            # TODO: Use wss instead of shelling out
            my $path = SBOM_PATH;
            my @lines = `kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- sh -c '[ -d "$path" ] && find "$path" -type f'`;

            # Store the spdx if we haven't seen it before
            for (@lines) {
              chomp;
              next unless $_;
              $spdx{$_} ||=  `kubectl exec -n "$namespace" "$pod_name" -c "$container_name" -- cat '$_'`;
            }

            warn "Could not enumerate packages in $container_image" unless @lines;
            $pacman_q{$container_image} = \@lines;
          }
      }
  }
  \%pacman_q, \%spdx
}

sub _generate_report {
  my ($ctrs, $scans) = @_;
  my $report;

  for my $ctr (keys %{$ctrs}) {
    my @installed = @{$ctrs->{$ctr}};
    for my $name (@installed) {
      if (exists $scans->{$name}) {
        push @{$scans->{$name}{affected_ctrs}}, $ctr;
      }
    }
  }
  for my $pkg (%$scans) {
    my $scan = $scans->{$pkg};
    for my $match (@{$scan->{matches}}) {
      my $vuln = $match->{vulnerability};
      $report .= "$vuln->{severity}: $match->{artifact}{name} is affected by $vuln->{id}: $vuln->{dataSource}";
      $report .= "\n";
      $report .= " $vuln->{description}\n";

      my @fixed_in = @{$vuln->{fix}{versions}};
      $report .=  join(' ', ' Update to', @fixed_in, "\n") if @fixed_in;
      $report .= " No fix available :(\n" unless @fixed_in;

      for my $ctr (@{$scan->{affected_ctrs}}[0 .. $affected_ctr_limit-1]) {
        $ctr =~ s/@.*$//;
        $report .= "  * $ctr\n" if $ctr;
      }
      $report .= "\n";
    }
  }
  $report
}

sub _spdx_to_scans {
  my $spdx = shift;

  my %scans;
  for (%$spdx) {
    open my $fh, '>', '/tmp/sbom.json' or die "Cannot open file: $!";
    my $content = $spdx->{$_};
    next unless $content;
    print $fh $content;

    # Close the file
    print "Scanning $_\n" if $verbose;
    $scans{$_} = decode_json(`grype sbom:/tmp/sbom.json --add-cpes-if-none --distro wolfi -o json`);
    close $fh;
  }

  return \%scans;
}


my ($ctrs, $spdx) = _installed_packages;

my $scans = _spdx_to_scans($spdx);

my $report = _generate_report($ctrs, $scans);

if ($mail_to and $report) {
  # Create a new email message
  my $msg = MIME::Lite->new(
    From    => $mail_from || 'scanner',
    To      => $mail_to,
    Subject => 'Vulnerability Report',
    Data    => $report,
  );

  $msg->send('smtp', $mail_server);
  print "Email sent successfully\n";
} else {
  print $report;
}
