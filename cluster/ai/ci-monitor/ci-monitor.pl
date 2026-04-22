#!/usr/bin/perl
use v5.20;
use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON::PP;
use URI::Escape qw(uri_escape);

my @REPOS = ('doudous/packages', 'doudous/apkontainers');
my $HOST  = $ENV{GITLAB_HOST} // 'https://gitlab.sko.ai';
my $TOKEN = $ENV{GITLAB_TOKEN} or die "GITLAB_TOKEN required\n";
my $LABEL = 'ci::main-failed';

my $DRY_RUN  = grep { $_ eq '--dry-run' } @ARGV;
my $ONLY_REPO;
for my $i (0 .. $#ARGV) {
    if ($ARGV[$i] eq '--repo' && defined $ARGV[$i+1]) {
        $ONLY_REPO = $ARGV[$i+1];
    } elsif ($ARGV[$i] =~ /^--repo=(.+)$/) {
        $ONLY_REPO = $1;
    }
}

my $ua = LWP::UserAgent->new(timeout => 30);
$ua->default_header('PRIVATE-TOKEN' => $TOKEN);

# Strip newlines from API-sourced strings to prevent GitLab quick-action injection
sub _sanitize { my $s = shift // ''; $s =~ s/[\r\n]+/ /g; return $s }

sub api_get {
    my ($path) = @_;
    my $url = "$HOST/api/v4$path";
    my $resp = $ua->get($url);
    unless ($resp->is_success) {
        warn "GET $url failed: " . $resp->status_line . "\n";
        return undef;
    }
    return decode_json($resp->decoded_content);
}

sub api_post {
    my ($path, %params) = @_;
    my $url = "$HOST/api/v4$path";
    if ($DRY_RUN) {
        say "  [dry-run] POST $path " . encode_json(\%params);
        return {};
    }
    my $resp = $ua->post($url, Content => encode_json(\%params),
                         'Content-Type' => 'application/json');
    unless ($resp->is_success) {
        warn "POST $url failed: " . $resp->status_line . " — " . $resp->decoded_content . "\n";
        return undef;
    }
    return decode_json($resp->decoded_content);
}

sub api_put {
    my ($path, %params) = @_;
    my $url = "$HOST/api/v4$path";
    if ($DRY_RUN) {
        say "  [dry-run] PUT $path " . encode_json(\%params);
        return {};
    }
    my $req = HTTP::Request->new(PUT => $url);
    $req->header('PRIVATE-TOKEN' => $TOKEN);
    $req->header('Content-Type'  => 'application/json');
    $req->content(encode_json(\%params));
    my $resp = $ua->request($req);
    unless ($resp->is_success) {
        warn "PUT $url failed: " . $resp->status_line . " — " . $resp->decoded_content . "\n";
        return undef;
    }
    return decode_json($resp->decoded_content);
}

sub ensure_label {
    my ($enc) = @_;
    # Create label if it doesn't exist; ignore 409 conflict
    my $url = "$HOST/api/v4/projects/$enc/labels";
    if ($DRY_RUN) {
        say "  [dry-run] ensure label '$LABEL' exists in project $enc";
        return;
    }
    my $resp = $ua->post($url,
        Content => encode_json({ name => $LABEL, color => '#e24329' }),
        'Content-Type' => 'application/json',
    );
    # 201 = created, 409 = already exists — both are fine
    unless ($resp->code == 201 || $resp->code == 409) {
        warn "Could not ensure label: " . $resp->status_line . "\n";
    }
}

sub process_repo {
    my ($repo) = @_;
    my $enc = uri_escape($repo, '^A-Za-z0-9\-._~');

    say "\n=== $repo ===";

    # 1. Get latest pipeline on main
    my $pipelines = api_get("/projects/$enc/pipelines?ref=main&per_page=1");
    unless ($pipelines && @$pipelines) {
        warn "No pipelines found for $repo\n";
        return;
    }
    my $pipeline = $pipelines->[0];
    my $status   = $pipeline->{status};
    my $sha      = $pipeline->{sha};
    my $pid      = $pipeline->{id};
    my $pipe_url = $pipeline->{web_url};

    say "  Latest pipeline: #$pid  status=$status  sha=$sha";

    # 2. Look for existing open issue with ci::main-failed label
    my $issues = api_get("/projects/$enc/issues?state=opened&labels=" . uri_escape($LABEL));
    my $existing = ($issues && @$issues) ? $issues->[0] : undef;

    if ($existing) {
        say "  Existing issue: #" . $existing->{iid} . " — " . $existing->{title};
    } else {
        say "  No existing issue.";
    }

    # 3. Decide action
    if ($status eq 'failed') {
        if (!$existing) {
            say "  Action: CREATE issue (pipeline failed, no open issue)";
            create_issue($repo, $enc, $pipeline);
        } else {
            # Check if this is a newer failing commit
            my $body = $existing->{description} // '';
            my ($stored_sha) = $body =~ /<!-- ci-monitor sha=(\S+)/;
            if ($stored_sha && $stored_sha ne $sha) {
                say "  Action: ADD NOTE (new failing commit $sha, was $stored_sha)";
                add_new_failure_note($enc, $existing->{iid}, $pipeline);
            } else {
                say "  Action: NO-OP (issue already open for same commit)";
            }
        }
    } elsif ($status eq 'success') {
        if ($existing) {
            say "  Action: CLOSE issue (pipeline now green)";
            close_issue($enc, $existing->{iid}, $pipe_url);
        } else {
            say "  Action: NO-OP (pipeline green, no open issue)";
        }
    } else {
        # running, pending, canceled, skipped, etc.
        say "  Action: NO-OP (status=$status, waiting for terminal state)";
    }
}

sub get_failed_jobs {
    my ($enc, $pid) = @_;
    my $jobs = api_get("/projects/$enc/pipelines/$pid/jobs?per_page=100");
    return () unless $jobs;
    return grep { $_->{status} eq 'failed' } @$jobs;
}

sub create_issue {
    my ($repo, $enc, $pipeline) = @_;

    ensure_label($enc);

    my $sha      = $pipeline->{sha};
    my $short    = substr($sha, 0, 8);
    my $pid      = $pipeline->{id};
    my $pipe_url = $pipeline->{web_url};

    # Fetch commit title
    my $commit = api_get("/projects/$enc/repository/commits/$sha");
    my $title  = _sanitize($commit ? $commit->{title} : '(unknown)');

    # Fetch failed jobs
    my @failed = get_failed_jobs($enc, $pid);

    my $jobs_md = '';
    if (@failed) {
        $jobs_md = "\n## Failed jobs\n";
        for my $job (@failed) {
            my $name   = _sanitize($job->{name});
            my $stage  = _sanitize($job->{stage});
            my $reason = _sanitize($job->{failure_reason} // 'unknown');
            $jobs_md .= "- [$name ($stage)]($job->{web_url}) — $reason\n";
        }
    }

    my $body = <<END;
Latest pipeline on \`main\` failed.

- Pipeline: $pipe_url
- Commit: $sha — $title
$jobs_md
<!-- ci-monitor sha=$sha pipeline=$pid -->
END

    my $issue_title = "CI failed on main: $short";
    say "  Creating issue: \"$issue_title\"";

    my $result = api_post("/projects/$enc/issues",
        title       => $issue_title,
        description => $body,
        labels      => $LABEL,
    );
    if ($result && $result->{iid}) {
        say "  Created issue #" . $result->{iid};
    }
}

sub add_new_failure_note {
    my ($enc, $iid, $pipeline) = @_;
    my $sha      = $pipeline->{sha};
    my $short    = substr($sha, 0, 8);
    my $pid      = $pipeline->{id};
    my $pipe_url = $pipeline->{web_url};

    my @failed = get_failed_jobs($enc, $pid);
    my $jobs_md = '';
    if (@failed) {
        $jobs_md = "\nFailed jobs:\n";
        for my $job (@failed) {
            my $name   = _sanitize($job->{name});
            my $stage  = _sanitize($job->{stage});
            my $reason = _sanitize($job->{failure_reason} // 'unknown');
            $jobs_md .= "- [$name ($stage)]($job->{web_url}) — $reason\n";
        }
    }

    my $note = "A new commit also failed on \`main\`:\n\n- Pipeline: $pipe_url\n- Commit: $sha\n$jobs_md\n<!-- ci-monitor sha=$sha pipeline=$pid -->";
    say "  Adding note to #$iid";

    api_post("/projects/$enc/issues/$iid/notes", body => $note);

    # Update sentinel in issue body by updating the issue description
    # (fetch current body, replace old sentinel with new one)
    my $issue = api_get("/projects/$enc/issues/$iid");
    if ($issue) {
        my $desc = $issue->{description} // '';
        $desc =~ s/<!-- ci-monitor sha=\S+ pipeline=\d+ -->/<!-- ci-monitor sha=$sha pipeline=$pid -->/;
        api_put("/projects/$enc/issues/$iid", description => $desc);
    }
}

sub close_issue {
    my ($enc, $iid, $pipe_url) = @_;
    say "  Adding close note to #$iid";
    api_post("/projects/$enc/issues/$iid/notes",
        body => "Auto-closed — latest pipeline on \`main\` is green: $pipe_url",
    );
    say "  Closing issue #$iid";
    api_put("/projects/$enc/issues/$iid", state_event => 'close');
}

# Main
my $failed_count = 0;
my @repos = $ONLY_REPO ? ($ONLY_REPO) : @REPOS;

say "ci-monitor starting" . ($DRY_RUN ? " [DRY RUN]" : "") . " — checking: " . join(', ', @repos);

for my $repo (@repos) {
    eval { process_repo($repo) };
    if ($@) {
        warn "ERROR processing $repo: $@\n";
        $failed_count++;
    }
}

if ($failed_count == scalar @repos) {
    die "All repos failed — exiting non-zero\n";
}

say "\nDone.";
