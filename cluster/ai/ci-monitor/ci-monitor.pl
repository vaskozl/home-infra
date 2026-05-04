#!/usr/bin/perl
# Monitor watched repos for currently-failing jobs on `main`.
#
# Concept: a job is identified by its name. A job is "currently broken" when
# its most-recent finished run on `main` (across all pipelines + their
# downstream bridge pipelines, recursive) has status=failed and no later
# successful run of the same job exists in the lookback window. This is robust
# to partial parallel pipelines (apkontainers triggers a separate pipeline per
# package) and to parent/child bridge pipelines (a green parent can hide a
# failed child).
#
# Each broken job's issue entry links to the failing job AND records the last
# green run (if any) for that job — this makes it obvious that we've already
# checked for a "subsequent pipeline succeeded" recovery before flagging.
#
# When the broken set is non-empty, file or update one issue per repo listing
# every broken job. When empty, close any open ci::main-failed issue.
use v5.20;
use utf8;
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(url_escape);
use Getopt::Long;
use POSIX qw(strftime);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my @REPOS  = ('doudous/packages', 'doudous/apkontainers');

my $HOST   = $ENV{GITLAB_HOST} // 'https://gitlab.sko.ai';
my $TOKEN  = $ENV{GITLAB_TOKEN} or die "GITLAB_TOKEN required\n";
my $LABEL  = 'ci::main-failed';
my $LOOKBACK_HOURS = 25;  # scan pipelines updated in the last N hours (25h gives overlap for daily crons)
my ($DRY, $REPO_ARG);
GetOptions('dry-run' => \$DRY, 'repo=s' => \$REPO_ARG) or die "bad args\n";

my $ua = Mojo::UserAgent->new;
$ua->on(start => sub { $_[1]->req->headers->header('PRIVATE-TOKEN' => $TOKEN) });

sub clean { (my $s = shift // '') =~ s/[\r\n]+/ /g; $s }
sub date  { substr(shift // '', 0, 10) }

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

# Fetch all pages from a GitLab API endpoint by following Link: rel="next" headers.
# Returns an arrayref of all items, or undef on the first API failure.
sub fetch_all {
    my ($start_url) = @_;
    my $url = $start_url;
    my @items;
    while ($url) {
        my $tx = $ua->get($url);
        my $r  = $tx->result;
        unless ($r->is_success) {
            warn "    GET $url -> " . $r->code . "\n";
            return undef;
        }
        push @items, @{ $r->json };
        my $link = $r->headers->header('Link') // '';
        ($url) = $link =~ /<([^>]+)>;\s*rel="next"/;
    }
    \@items
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

    my $since = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time - $LOOKBACK_HOURS * 3600));
    my $pipes = fetch_all("$HOST/api/v4/projects/$e/pipelines?ref=main&updated_after=" . url_escape($since) . "&per_page=100") // [];
    say "  scanning " . scalar(@$pipes) . " main pipelines updated since $since";

    # Track every finished run per job name, then for each name find:
    #   - the latest run (decides current state)
    #   - the last successful run (if any — included in the issue for context)
    # A job is only broken when its latest run is failed AND no later success
    # exists. The grep is defensive (the sort already makes latest first), but
    # makes the "subsequent success skips creation" rule explicit and visible.
    my %runs;
    for my $p (@$pipes) {
        for my $j (walk_jobs($e, $p->{id})) {
            next unless $j->{finished_at};
            push @{$runs{$j->{name}}}, $j;
        }
    }
    my (@broken, $recovered);
    for my $name (sort keys %runs) {
        my @sorted = sort { $b->{finished_at} cmp $a->{finished_at} } @{$runs{$name}};
        my $latest = $sorted[0];
        next unless $latest->{status} eq 'failed';
        if (grep { $_->{status} eq 'success' && $_->{finished_at} gt $latest->{finished_at} } @sorted) {
            $recovered++;
            next;
        }
        my ($last_ok) = grep { $_->{status} eq 'success' } @sorted;
        push @broken, { %$latest, _last_success => $last_ok };
    }
    say "  skipped $recovered job(s) with a later successful run" if $recovered;

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
    for my $b (@broken) {
        my $g = $b->{_last_success};
        my $note = $g ? "last green " . date($g->{finished_at}) . " (#$g->{_pid})"
                      : "no green run in window";
        say "    - $b->{name}  -> $b->{web_url}  [$note]";
    }

    my @names = map { $_->{name} } @broken;
    my $sentinel = "<!-- ci-monitor jobs=" . join(',', @names) . " -->";
    my $title = "CI failed on main: " . scalar(@broken) . " job" . (@broken > 1 ? 's' : '');
    my $body  = "Currently-failing jobs on `main` (latest finished run is `failed`,"
              . " no later success in last ${LOOKBACK_HOURS}h):\n\n"
              . join('', map {
                  my $g = $_->{_last_success};
                  my $green = $g
                      ? sprintf('last green %s ([#%d](%s))',
                                date($g->{finished_at}), $g->{_pid}, $g->{web_url})
                      : "_never green in last ${LOOKBACK_HOURS}h of main pipelines_";
                  sprintf("- [`%s` (`%s`)](%s) failed %s — %s (pipeline #%d); %s\n",
                      clean($_->{name}), clean($_->{stage}), $_->{web_url},
                      date($_->{finished_at}), clean($_->{failure_reason} // 'unknown'),
                      $_->{_pid}, $green)
                } @broken)
              . "\n_Filed by [ci-monitor](https://gitlab.sko.ai/doudous/home-infra/-/tree/main/cluster/ai/ci-monitor)._"
              . " Close this issue manually if a listed job is no longer relevant"
              . " (e.g. package removed, job renamed) — ci-monitor will reopen a fresh"
              . " issue if the same name reappears as failing on `main`.\n"
              . "\n$sentinel";

    if (!$open) {
        say "  action: CREATE issue";
        api(POST => "/projects/$e/labels", { name => $LABEL, color => '#e24329' });
        api(POST => "/projects/$e/issues",
            { title => $title, description => $body, labels => $LABEL });
        return;
    }

    my ($prev) = ($open->{description} // '') =~ /<!-- ci-monitor jobs=(.+?) -->/;
    my $set_changed = (($prev // '') ne join(',', @names));
    my $body_drift  = (($open->{description} // '') ne $body);
    if (!$set_changed && !$body_drift) {
        say "  action: NO-OP (issue #$open->{iid} already lists these jobs)";
        return;
    }
    if (!$set_changed) {
        # same broken set, just stale description (encoding fix, formatting tweak,
        # link refresh): silently re-PUT, no note — avoid pinging subscribers.
        say "  action: REFRESH issue #$open->{iid} description (set unchanged)";
        api(PUT => "/projects/$e/issues/$open->{iid}", { title => $title, description => $body });
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
