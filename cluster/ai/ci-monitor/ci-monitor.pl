#!/usr/bin/perl
use v5.20;
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(url_escape);
use Getopt::Long;

my @REPOS = ('doudous/packages', 'doudous/apkontainers');
my $HOST  = $ENV{GITLAB_HOST} // 'https://gitlab.sko.ai';
my $TOKEN = $ENV{GITLAB_TOKEN} or die "GITLAB_TOKEN required\n";
my $LABEL = 'ci::main-failed';
my ($DRY, $REPO);
GetOptions('dry-run' => \$DRY, 'repo=s' => \$REPO);

my $ua = Mojo::UserAgent->new;
$ua->on(start => sub { $_[1]->req->headers->header('PRIVATE-TOKEN' => $TOKEN) });

sub clean { (my $s = shift // '') =~ s/[\r\n]+/ /g; $s }

sub api {
    my ($m, $path, %p) = @_;
    if ($DRY && $m ne 'GET') { say "  [dry] $m $path"; return {} }
    my $r = ($m eq 'GET' ? $ua->get("$HOST/api/v4$path")
                         : $ua->$m("$HOST/api/v4$path" => {'Content-Type' => 'application/json'} => encode_json(\%p)))->result;
    $r->is_success ? $r->json : do { warn "$m $path: " . $r->code . "\n"; undef }
}

sub failed_jobs_md {
    my ($e, $pid) = @_;
    my @f = grep { $_->{status} eq 'failed' } @{api(GET => "/projects/$e/pipelines/$pid/jobs?per_page=100") // []};
    @f ? "\n\n## Failed jobs\n" . join('', map {
        "- [" . clean($_->{name}) . " (" . clean($_->{stage}) . ")]($_->{web_url}) — " . clean($_->{failure_reason} // 'unknown') . "\n"
    } @f) : ''
}

sub process {
    my ($repo) = @_;
    my $e = url_escape($repo, '^A-Za-z0-9\-._~');
    say "\n=== $repo ===";

    my $pipes = api(GET => "/projects/$e/pipelines?ref=main&per_page=1") or return;
    @$pipes or return warn "No pipelines found\n";
    my ($st, $sha, $pid, $purl) = @{$pipes->[0]}{qw(status sha id web_url)};
    say "  Latest pipeline: #$pid  status=$st  sha=$sha";

    my $issues = api(GET => "/projects/$e/issues?state=opened&labels=" . url_escape($LABEL));
    my $open   = $issues && @$issues ? $issues->[0] : undef;
    say $open ? "  Existing issue: #$open->{iid}" : "  No existing issue";

    if ($st eq 'failed' && !$open) {
        say "  Action: CREATE issue";
        unless ($DRY) {
            $ua->post("$HOST/api/v4/projects/$e/labels" =>
                {'Content-Type' => 'application/json'} => encode_json({name => $LABEL, color => '#e24329'}))->result;
        }
        my $c = api(GET => "/projects/$e/repository/commits/$sha") // {};
        api(POST => "/projects/$e/issues",
            title       => "CI failed on main: " . substr($sha, 0, 8),
            description => "Latest pipeline on \`main\` failed.\n\n- Pipeline: $purl\n"
                . "- Commit: $sha — " . clean($c->{title}) . failed_jobs_md($e, $pid)
                . "\n\n<!-- ci-monitor sha=$sha pipeline=$pid -->",
            labels => $LABEL);

    } elsif ($st eq 'failed' && $open) {
        my ($prev) = ($open->{description} // '') =~ /<!-- ci-monitor sha=(\S+)/;
        if ($prev && $prev ne $sha) {
            say "  Action: ADD NOTE (new failing commit $sha, was $prev)";
            api(POST => "/projects/$e/issues/$open->{iid}/notes",
                body => "New commit also failed on \`main\`:\n\n- Pipeline: $purl\n- Commit: $sha"
                    . failed_jobs_md($e, $pid));
            unless ($DRY) {
                (my $desc = $open->{description} // '') =~
                    s|<!-- ci-monitor sha=\S+ pipeline=\d+ -->|<!-- ci-monitor sha=$sha pipeline=$pid -->|;
                api(PUT => "/projects/$e/issues/$open->{iid}", description => $desc);
            }
        } else {
            say "  Action: NO-OP (issue already open for this commit)";
        }

    } elsif ($st eq 'success' && $open) {
        say "  Action: CLOSE issue #$open->{iid}";
        api(POST => "/projects/$e/issues/$open->{iid}/notes",
            body => "Auto-closed — latest pipeline on \`main\` is green: $purl");
        api(PUT => "/projects/$e/issues/$open->{iid}", state_event => 'close');

    } else {
        say "  Action: NO-OP (status=$st)";
    }
}

my @repos = $REPO ? ($REPO) : @REPOS;
say "ci-monitor" . ($DRY ? " [DRY RUN]" : "") . " — checking: " . join(', ', @repos);
my $errs = 0;
for my $r (@repos) { eval { process($r) } or do { warn "ERROR: $@"; $errs++ } }
die "All repos failed\n" if $errs == @repos;
say "\nDone.";
