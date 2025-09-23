#!/usr/bin/perl
use strict;
use warnings;
use feature qw(say);

use JSON::XS qw(decode_json encode_json);
use MIME::Lite;
use Mojolicious::Lite;
use Mojo::UserAgent;
use Path::Tiny;

use constant ARCH_SECURITY => 'https://security.archlinux.org/issues/all.json';
use constant IMAGE_FILTER  => qr{ghcr[.]io/vaskozl};
use constant SA_TOKEN      => '/var/run/secrets/kubernetes.io/serviceaccount/token';
use constant SBOM_PATH     => '/var/lib/db/sbom';
use constant RPT_CTR_LIMIT => 5;
use constant SCAN_PERIOD   => 6 * 3600; # 6 hours

my $ua = Mojo::UserAgent->new->insecure(1);
my $token = path(SA_TOKEN)->slurp;
my $k8s_api = 'https://kubernetes.default.svc.cluster.local';
my %metrics;

sub _k8s_headers { { 'Authorization' => "Bearer $token", 'Accept' => 'application/json' } }

sub _installed_packages {
  my $pod_data = $ua->get($k8s_api .
    '/api/v1/pods?fieldSelector=status.phase=Running',
    _k8s_headers
  )->result->json;

  my %pacman_q;
  my %spdx;
  my %processed_images;
  my $i = 0;
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
            say "Extracting sbom of $container_image";
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
  %metrics = ();

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
      my $name = $match->{artifact}{name};

      $report .= "$vuln->{severity}: $name is affected by $vuln->{id}: $vuln->{dataSource}";
      $report .= "\n";
      $report .= " $vuln->{description}\n";

      my @fixed_in = @{$vuln->{fix}{versions}};
      $report .=  join(' ', ' Update to', @fixed_in, "\n") if @fixed_in;
      $report .= " No fix available :(\n" unless @fixed_in;

      for my $ctr (@{$scan->{affected_ctrs}}[0 .. RPT_CTR_LIMIT-1]) {
        $ctr =~ s/@.*$//;
        next unless $ctr;

        $report .= "  * $ctr\n";

        my %labels = (
          id       => $vuln->{id},
          severity => $vuln->{severity},
          pkg      => $name,
          fixed    => shift @fixed_in,
          image    => $ctr
        );

        my $label_string = join(",", map { "$_=\"$labels{$_}\"" } keys %labels);
        $metrics{$label_string}++;
      }
      $report .= "\n";
    }
  }
  $report
}

sub _spdx_to_scans {
  my $spdx = shift;

  `grype db update`;

  my %scans;
  my $i = 0;
  for (%$spdx) {
      open my $fh, '>', '/tmp/sbom.json' or die "Cannot open file: $!";
      my $content = $spdx->{$_};
      next unless $content;
      print $fh $content;

      # Close the file
      say "Scanning $_";
      $scans{$_} = decode_json(`GRYPE_DB_AUTO_UPDATE=false grype sbom:/tmp/sbom.json --add-cpes-if-none --distro wolfi -o json`);
      close $fh;
  }

  return \%scans;
}


sub _run_all {
  my ($ctrs, $spdx) = _installed_packages;

  my $scans = _spdx_to_scans($spdx);

  my $report = _generate_report($ctrs, $scans);

  if ($ENV{'MAIL_TO'} and $report) {
    # Create a new email message
    my $msg = MIME::Lite->new(
      From    => $ENV{'SCAN_MAIL_FROM'} || 'scanner',
      To      => $ENV{'SCAN_MAIL_TO'},
      Subject => 'Vulnerability Report',
      Data    => $report,
    );

    $msg->send('smtp', $ENV{'SCAN_MAIL_SERVER'});
    say "Email sent successfully";
  } else {
    print $report;
  }
}

# Expose some prometheus metrics like a good k8s citizen
get '/metrics' => sub {
  my $c = shift;

  my $txt = "# HELP container_vulns The number of CVEs\n";
  while(my ($labels, $cnt) = each %metrics) {
    $txt .= "container_vulns{$labels} $cnt\n";
  }

  $c->render(text => $txt);
};

Mojo::IOLoop->recurring(int(SCAN_PERIOD) => sub { _run_all() });
Mojo::IOLoop->timer(0 => sub { _run_all() });

app->start('daemon', '-l', 'http://[::]:9090');
