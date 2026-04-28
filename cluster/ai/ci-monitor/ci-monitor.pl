#!/usr/bin/perl
# Monitor watched repos for currently-failing jobs on `main`.
#
# Concept: a job is identified by its name. A job is "currently broken" when
# its most-recent finished run on `main` (across all pipelines + their
# downstream bridge pipelines, recursive) has status=failed. This is robust to
# partial parallel pipelines (apkontainers triggers a separate pipeline per
# package) and to parent/child bridge pipelines (a green parent can hide a
# failed child).
#
# When the broken set is non-empty, file or update one issue per repo listing
# every broken job. When empty, close any open ci::main-failed issue.
use v5.20;
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(url_escape);
use Getopt::Long;

my @REPOS  = ('doudous/packages', 'doudous/apkontainers');
my $HOST   = $ENV{GITLAB_HOST} // 'https://gitlab.sko.ai';
my $TOKEN  = $ENV{GITLAB_TOKEN} or die "GITLAB_TOKEN required\n";
my $LABEL  = 'ci::main-failed';
my $LOOKBACK = 100;  # number of recent main pipelines to scan
my ($DRY, $REPO_ARG);
GetOptions('dry-run' => \$DRY, 'repo=s' => \$REPO_ARG) or die "bad args\n";

my $ua = Mojo::UserAgent->new;
$ua->on(start => sub { $_[1]->req->headers->header('PRIVATE-TOKEN' => $TOKEN) });

sub clean { (my $s = shift // '') =~ s/[\r\n]+/ /g; $s }

sub api {
    my ($method, $path, $body) = @_;
    if ($DRY && $method ne 'GET') { say "    [dry] $method $path"; return { iid => 0, id => 0 } }
    my $m = lc $method;
    my $tx = $body
        ? $ua->$m("$HOST/api/v4$path" => {'Content-Type' => 'application/json'} => encode_json($body))
        : $ua->$m("$HOST/api/v4$path");
    my $r = $tx->result;
    return $r->json if $r->is_success;
    warn "    $method $path -> " . $r->code . "\n";
    undef
}

# Walk a pipeline + all its downstream bridge pipelines (recursive),
# returning every leaf job. $seen guards against cycles.
sub walk_jobs {
    my ($e, $pid, $seen) = @_;
    $seen //= {};
    return () if $seen->{$pid}++;
    my @jobs = map { +{ %$_, _pid => $pid } }
        @{ api(GET => "/projects/$e/pipelines/$pid/jobs?per_page=100") // [] };
    for my $b (@{ api(GET => "/projects/$e/pipelines/$pid/bridges?per_page=100") // [] }) {
        my $dp = $b->{downstream_pipeline} or next;
        push @jobs, walk_jobs($e, $dp->{id}, $seen);
    }
    @jobs
}

sub process {
    my ($repo) = @_;
    my $e = url_escape($repo, '^A-Za-z0-9\-._~');
    say "\n=== $repo ===";

    my $pipes = api(GET => "/projects/$e/pipelines?ref=main&per_page=$LOOKBACK") // [];
    say "  scanning last " . scalar(@$pipes) . " main pipelines";

    # For each job name, keep only the most recent finished run.
    my %latest;
    for my $p (@$pipes) {
        for my $j (walk_jobs($e, $p->{id})) {
            next unless $j->{finished_at};
            my $cur = $latest{$j->{name}};
            $latest{$j->{name}} = $j if !$cur || $j->{finished_at} gt $cur->{finished_at};
        }
    }
    my @broken = sort { $a->{name} cmp $b->{name} }
                 grep { $_->{status} eq 'failed' } values %latest;

    my $open = (api(GET => "/projects/$e/issues?state=opened&labels=" . url_escape($LABEL)) // [])->[0];

    if (!@broken) {
        say "  all jobs green";
        return unless $open;
        say "  action: CLOSE issue #$open->{iid}";
        api(POST => "/projects/$e/issues/$open->{iid}/notes",
            { body => "Auto-closed — all `main` jobs are green." });
        api(PUT  => "/projects/$e/issues/$open->{iid}", { state_event => 'close' });
        return;
    }

    say "  broken jobs (" . scalar(@broken) . "):";
    say "    - $_->{name}  -> $_->{web_url}" for @broken;

    my @names = map { $_->{name} } @broken;
    my $sentinel = "<!-- ci-monitor jobs=" . join(',', @names) . " -->";
    my $title = "CI failed on main: " . scalar(@broken) . " job" . (@broken > 1 ? 's' : '');
    my $body  = "Currently-failing jobs on `main` (latest finished run is `failed`):\n\n"
              . join('', map {
                  sprintf("- [`%s` (`%s`)](%s) — %s (pipeline #%d)\n",
                      clean($_->{name}), clean($_->{stage}),
                      $_->{web_url}, clean($_->{failure_reason} // 'unknown'), $_->{_pid})
                } @broken)
              . "\n$sentinel";

    if (!$open) {
        say "  action: CREATE issue";
        api(POST => "/projects/$e/labels", { name => $LABEL, color => '#e24329' });
        api(POST => "/projects/$e/issues",
            { title => $title, description => $body, labels => $LABEL });
        return;
    }

    my ($prev) = ($open->{description} // '') =~ /<!-- ci-monitor jobs=(\S+) -->/;
    if (($prev // '') eq join(',', @names)) {
        say "  action: NO-OP (issue #$open->{iid} already lists these jobs)";
        return;
    }
    say "  action: UPDATE issue #$open->{iid} (broken set changed: " . ($prev // '(none)') . " -> " . join(',', @names) . ")";
    api(PUT  => "/projects/$e/issues/$open->{iid}", { title => $title, description => $body });
    api(POST => "/projects/$e/issues/$open->{iid}/notes",
        { body => "Broken-job set changed.\n\n$body" });
}

my @repos = $REPO_ARG ? ($REPO_ARG) : @REPOS;
say "ci-monitor" . ($DRY ? " [DRY RUN]" : "") . " — checking: " . join(', ', @repos);
my $errs = 0;
for my $r (@repos) { eval { process($r); 1 } or do { warn "ERROR in $r: $@"; $errs++ } }
die "All repos failed\n" if $errs == @repos;
say "\nDone.";
