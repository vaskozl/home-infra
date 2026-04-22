#!/usr/bin/perl
# ralph — Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx>
use v5.38;
no warnings 'experimental';
use Getopt::Long  qw(GetOptions);
use Mojo::UserAgent;
use Mojo::JSON    qw(decode_json);
use Mojo::URL;
use Mojo::Util    qw(url_escape);

use constant PROMPT_DIR       => '/etc/claude';
use constant COMMON_PROMPT    => PROMPT_DIR . '/prompt-common.md';
use constant SLEEP_INTERVAL   => $ENV{SLEEP_INTERVAL}   // 300;
use constant TIMEOUT_INTERVAL => $ENV{TIMEOUT_INTERVAL} // 60;

my $UA = Mojo::UserAgent->new->request_timeout(30);
$UA->on(start => sub ($ua, $tx) {
    $tx->req->headers->header('PRIVATE-TOKEN' => $ENV{GITLAB_TOKEN});
});
my $API_BASE = ($ENV{GITLAB_HOST} // 'https://gitlab.sko.ai') . '/api/v4';

# ---------------------------------------------------------------------------
# GitLab helpers
# ---------------------------------------------------------------------------

sub _gl_api ($path) {
    my $res = eval { $UA->get("$API_BASE/$path")->result } or return undef;
    return undef unless $res->is_success;
    eval { $res->json };
}

sub _run (@cmd) {
    open my $fh, '-|', @cmd or return '';
    local $/;
    <$fh> // '';
}

sub gl_repos () {
    my $data = eval { decode_json(scalar qx(glab repo list -a --output json 2>/dev/null)); };
    $data ? map { $_->{path_with_namespace} } @$data : ();
}

use constant IGNORE_TITLE_RE => qr/renovate dashboard/i;

sub gl_issues ($repo, @args) {
    my $out = _run('glab', 'issue', 'list', '-R', $repo, @args);
    join "\n", grep { !/${\ IGNORE_TITLE_RE}/ } split /\n/, $out;
}

sub gl_issues_api ($repo, @labels) {
    my $enc = url_escape($repo);
    my $lbl = join ',', map { url_escape($_) } @labels;
    my $r   = _gl_api("projects/$enc/issues?labels=$lbl&state=opened&per_page=100");
    return [] unless ref($r) eq 'ARRAY';
    [ grep { ($_->{title} // '') !~ IGNORE_TITLE_RE } @$r ];
}

sub gl_open_mrs ($repo, @labels) {
    my $enc    = url_escape($repo);
    my @params = ('state=opened', 'per_page=100');
    push @params, 'labels=' . join(',', map { url_escape($_) } @labels)
      if @labels;
    my $r = _gl_api("projects/${enc}/merge_requests?" . join('&', @params));
    ref($r) eq 'ARRAY' ? $r : [];
}

sub _has_agent_label (@labels) {
    grep { /^agent::/ } @labels;
}

sub gl_is_claimed ($repo, $iid) {
    my $enc   = url_escape($repo);
    my $issue = _gl_api("projects/${enc}/issues/$iid") or return 0;
    _has_agent_label(@{$issue->{labels} // []});
}

sub gl_has_open_mr ($repo, $iid) {
    my $enc = url_escape($repo);
    my $mrs = _gl_api("projects/${enc}/issues/${iid}/related_merge_requests") or return 0;
    ref($mrs) eq 'ARRAY' && grep { ($_->{state} // '') eq 'opened' } @$mrs;
}

sub gl_has_unresolved_blockers ($repo, $iid) {
    my $enc   = url_escape($repo);
    my $issue = _gl_api("projects/${enc}/issues/$iid") or return 0;

    my (@blockers, $in);
    for (split /\n/, $issue->{description} // '') {
        if    (/^## Blocked by/)   { $in = 1; next }
        elsif ($in && /^## /)      { $in = 0 }
        elsif ($in && /^- #(\d+)/) { push @blockers, $1 }
    }
    return 0 unless @blockers;

    for my $bid (@blockers) {
        my $b = _gl_api("projects/${enc}/issues/${bid}") or next;
        return 1 if ($b->{state} // 'opened') ne 'closed';
    }
    0;
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

sub _repos_header (@repos) {
    sprintf "\n## Repos\n```\n%s\n```\n", join "\n", @repos;
}

sub _format_mr ($mr) {
    sprintf "!%d\t%s\t%s\t(main) ← (%s)",
      $mr->{iid}, $mr->{references}{full}, $mr->{title}, $mr->{source_branch};
}

sub _mr_block ($repo, @mrs) {
    sprintf "### %s\n```\n%s\n```\n", $repo, join "\n", map { _format_mr($_) } @mrs;
}

sub _section ($header, $body) {
    $body =~ /\S/ ? "\n## $header\n$body\n" : '';
}

sub _repo_block ($repo, $text) {
    return '' unless $text && $text =~ /\S/;
    $text =~ s/\s+\z//;
    "### $repo\n```\n$text\n```\n";
}

# ---------------------------------------------------------------------------
# Prompt builders
# ---------------------------------------------------------------------------

sub dev_prompt (@repos) {
    my $out = _repos_header(@repos);

    my $mine = '';
    for my $repo (@repos) {
        my @issues = @{gl_issues_api($repo, "agent::$ENV{HOSTNAME}")};
        # Skip issues already in review — dev has nothing to do until human acts.
        @issues = grep {
            !grep { $_ eq 'workflow::in review' } @{$_->{labels} // []}
        } @issues;
        next unless @issues;
        my $text = join "\n", map { sprintf "#%d\t%s", $_->{iid}, $_->{title} } @issues;
        $mine .= _repo_block($repo, $text);
    }
    $out .= _section('My in-progress issues', $mine);

    # MRs this agent was working on (left from a previous run)
    my $my_mrs = '';
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo, "agent::$ENV{HOSTNAME}", "workflow::in dev");
        $my_mrs .= _mr_block($repo, @$mrs) if @$mrs;
    }
    $out .= _section('My in-progress MRs', $my_mrs);

    # Issues stuck in "in dev" with no agent claim (orphaned)
    my $stale = '';
    for my $repo (@repos) {
        my @issues = @{gl_issues_api($repo, 'workflow::in dev', "model::$ENV{ANTHROPIC_MODEL}")};
        my @unclaimed =
          grep { !gl_has_open_mr($repo, $_->{iid}) }
          grep { !_has_agent_label(@{$_->{labels} // []}) }
          @issues;
        next unless @unclaimed;
        my $text = join "\n", map { sprintf "#%d\t%s", $_->{iid}, $_->{title} } @unclaimed;
        $stale .= _repo_block($repo, $text);
    }
    $out .= _section('Unclaimed in-dev issues', $stale);

    # New work available
    my $ready = '';
    for my $repo (@repos) {
        my $t = gl_issues(
            $repo,     '--label', 'workflow::ready for development',
            '--label', "model::$ENV{ANTHROPIC_MODEL}",
        );
        next unless $t =~ /^#/m;
        my $filtered = join "\n",
          grep { /^#(\d+)/ && !gl_is_claimed($repo, $1) && !gl_has_unresolved_blockers($repo, $1) }
          split /\n/, $t;
        $ready .= _repo_block($repo, $filtered);
    }
    $out .= _section('Issues ready for dev', $ready);

    # MR triage (CI failures, conflicts, human feedback)
    my %excl = map { $_ => 1 } 'workflow::in review', 'workflow::in dev';
    my ($ci_fail, $conflicts, $needs_work) = ('', '', '');
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo, "model::$ENV{ANTHROPIC_MODEL}");
        my @f   = grep { ($_->{head_pipeline}{status} // '') eq 'failed' } @$mrs;
        my @c   = grep { $_->{has_conflicts} } @$mrs;
        my @w   = grep {
            !$_->{has_conflicts} && !grep { $excl{$_} }
              @{$_->{labels}}
        } @$mrs;
        $ci_fail    .= _mr_block($repo, @f) if @f;
        $conflicts  .= _mr_block($repo, @c) if @c;
        $needs_work .= _mr_block($repo, @w) if @w;
    }
    $out .= _section('MRs with failed CI', $ci_fail);
    $out .= _section('MRs with conflicts', $conflicts);
    $out .= _section('MRs needing work',   $needs_work);
    $out;
}

sub lead_prompt (@repos) {
    my $out = _repos_header(@repos);

    my $wake = '';
    for my $repo (@repos) {
        my $t = gl_issues($repo, '--label', 'wake::lead');
        $wake .= _repo_block($repo, $t) if $t =~ /^#/m;
    }
    $out .= _section('Issues flagged wake::lead (dev wants re-plan)', $wake);

    my $ci_fail = '';
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo);
        my @f   = grep { ($_->{head_pipeline}{status} // '') eq 'failed' } @$mrs;
        $ci_fail .= _mr_block($repo, @f) if @f;
    }
    $out .= _section('MRs with failed CI', $ci_fail);

    my @not_labels = map { ('--not-label', $_) } (
        'workflow::ready for development', 'workflow::in dev',
        'workflow::in review',             'workflow::blocked',
        'renovate',                        'type::dx-audit',
        'claude::ignore',
    );
    my $planning = '';
    for my $repo (@repos) {
        my $t = gl_issues($repo, @not_labels);
        $planning .= _repo_block($repo, $t) if $t =~ /^#/m;
    }
    $out .= _section('Issues needing planning', $planning);
    $out;
}

sub reviewer_prompt (@repos) {
    my $out = _repos_header(@repos);

    my ($ready, $renovate) = ('', '');
    for my $repo (@repos) {
        my $enc = url_escape($repo);
        my $mrs = gl_open_mrs($repo);
        my (@r, @ren);
        for my $mr (@$mrs) {
            my @labels = @{$mr->{labels} // []};
            next if grep { $_ eq 'claude::ignore' || $_ eq 'review::deferred' } @labels;
            next if ($mr->{head_pipeline}{status} // '') eq 'failed';
            my $is_renovate = ($mr->{source_branch} // '') =~ m{^renovate/};
            my $in_review   = grep { $_ eq 'workflow::in review' } @labels;
            next unless $is_renovate || $in_review;
            # Deliberately NOT filtering agent::* here — workflow::in review is the
            # authoritative "dev is done" signal; any agent::* on an in-review MR is
            # a stale claim the dev forgot to strip. The 10s verify on claim handles
            # multi-reviewer races.
            my $a = _gl_api("projects/$enc/merge_requests/$mr->{iid}/approvals");
            next if $a && ($a->{approved} || @{$a->{approved_by} // []});
            if ($is_renovate) { push @ren, $mr }
            else              { push @r,   $mr }
        }
        $ready    .= _mr_block($repo, @r)   if @r;
        $renovate .= _mr_block($repo, @ren) if @ren;
    }
    $out .= _section('MRs awaiting review',          $ready);
    $out .= _section('Renovate MRs awaiting review', $renovate);
    $out;
}

sub dx_prompt (@repos) {
    my $out = _repos_header(@repos);
    chomp(my $ts = qx(date -Iseconds));
    $out .= "\n## DX audit — $ts\n";
    $out .= <<'END';
Agent logs live at /logs/ai/ on the ripgrep pod.
Each line: <JSON> pod=<pod> ctr=<ctr> ts=<ts> — strip trailing fields before piping to jq:

```bash
# Recent agent sessions (result lines carry cost, turns, outcome)
kubectl exec -n logging ripgrep-0 -- rg '"type":"result"' /logs/ai/claude-worker-sonnet.log | \
  tail -20 | sed 's/ pod=[^ ]* ctr=[^ ]* ts=[^ ]*//' | \
  jq '{pod: .session_id, cost: .total_cost_usd, turns: .num_turns, ok: (.is_error | not), preview: .result[:120]}'
```
END
    $out;
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

my %ROLES = (
    dev => {
        label      => 'Iteration',
        idle       => 'Nothing to do, sleeping',
        idle_sleep => TIMEOUT_INTERVAL,
        prompt     => \&dev_prompt
    },
    lead => {
        label      => 'Planner iteration',
        idle       => 'No unrefined issues, sleeping',
        idle_sleep => TIMEOUT_INTERVAL,
        prompt     => \&lead_prompt
    },
    reviewer => {
        label      => 'Review iteration',
        idle       => 'No MRs to review, sleeping',
        idle_sleep => TIMEOUT_INTERVAL,
        prompt     => \&reviewer_prompt
    },
    dx => {
        label      => 'DX audit',
        idle       => 'No analysis needed, sleeping',
        idle_sleep => SLEEP_INTERVAL,
        prompt     => \&dx_prompt
    },
);

sub run_loop ($role, $prompt_file, $dry_run) {
    my @repos = gl_repos;
    if ($dry_run) { print $role->{prompt}->(@repos); return }

    require File::Temp;
    my $sys = File::Temp->new(
        UNLINK => 1,
        SUFFIX => '.md'
    );
    my $syspath = $sys->filename;
    for my $f (COMMON_PROMPT, $prompt_file) {
        open my $fh, '<', $f or die "Cannot read $f: $!\n";
        local $/;
        print $sys readline($fh);
    }
    $sys->flush;

    my $i = 0;
    while (1) {
        $i++;
        chomp(my $ts = qx(date -Iseconds));
        printf "=== %s %d — %s ===\n", $role->{label}, $i, $ts;

        my ($ord) = ($ENV{HOSTNAME} // '') =~ /(\d+)$/;
        sleep(($ord // 0) * 240 + int rand 60);

        @repos = gl_repos;
        my $prompt = $role->{prompt}->(@repos);

        unless ($prompt =~ /^## [^R]/m) {
            print "--- $role->{idle} ---\n";
            sleep $role->{idle_sleep};
            next;
        }

        my ($output, $has_sleep) = ('', 0);
        open my $pipe, '-|',
          'claude',               '-p', $prompt,
          '--system-prompt-file', $syspath,
          '--verbose',            '--dangerously-skip-permissions',
          '--output-format',      'stream-json'
          or do {
            warn "Failed to launch claude: $!\n";
            sleep TIMEOUT_INTERVAL;
            next;
          };

        while (my $line = <$pipe>) {
            print $line;
            $output .= $line;
            $has_sleep = 1 if $line =~ m{<sleep/>};
        }
        close $pipe;
        my $exit_code = $? >> 8;

        if ($exit_code != 0) {
            die "FATAL: Auth failure — token expired or invalid. Exiting.\n"
              if $output =~
              /OAuth token has expired|token.*expired|HTTP 401|API Error: 401|authentication_error/;
            warn "claude exited with code $exit_code\n";
        }

        if ($has_sleep) { print "--- Sleeping ---\n"; sleep SLEEP_INTERVAL }
        else            { sleep TIMEOUT_INTERVAL }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

my $dry_run = 0;

GetOptions('dry-run|n' => \$dry_run)
  or die "Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx>\n";

my $cmd  = shift @ARGV  // die "Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx>\n";
my $role = $ROLES{$cmd} // die "Unknown command: $cmd\n";

run_loop($role, PROMPT_DIR . "/prompt-${cmd}.md", $dry_run);
