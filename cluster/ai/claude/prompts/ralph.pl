#!/usr/bin/perl
# ralph — Usage: ralph [--dry-run|-n] <dev|lead|dx>
use v5.38;
no warnings 'experimental';
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);

use constant PROMPT_DIR       => '/etc/claude';
use constant COMMON_PROMPT    => PROMPT_DIR . '/prompt-common.md';
use constant SLEEP_INTERVAL   => $ENV{SLEEP_INTERVAL}   // 300;
use constant TIMEOUT_INTERVAL => $ENV{TIMEOUT_INTERVAL} // 60;

# ---------------------------------------------------------------------------
# GitLab helpers
# ---------------------------------------------------------------------------

sub _gl_api($path) {
    my $json = qx(glab api '$path' 2>/dev/null) // '';
    return undef unless $json =~ /\S/;
    eval { decode_json($json) };
}

sub _run(@cmd) {
    open my $fh, '-|', @cmd or return '';
    local $/;
    <$fh> // '';
}

sub _urlencode($s) {
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;
    $s;
}

sub gl_repos() {
    my $data = eval {
        decode_json(scalar qx(glab repo list -a --output json 2>/dev/null))
    };
    $data ? map { $_->{path_with_namespace} } @$data : ();
}

sub gl_issues($repo, @args) { _run('glab', 'issue', 'list', '-R', $repo, @args) }

sub gl_open_mrs($repo, @labels) {
    my $enc    = _urlencode($repo);
    my @params = ('state=opened', 'per_page=100');
    push @params, 'labels=' . join(',', map { _urlencode($_) } @labels) if @labels;
    my $r = _gl_api("projects/${enc}/merge_requests?" . join('&', @params));
    ref($r) eq 'ARRAY' ? $r : [];
}

sub gl_is_claimed($repo, $iid) {
    my $enc   = _urlencode($repo);
    my $issue = _gl_api("projects/${enc}/issues/$iid") or return 0;
    grep { /^agent::/ } @{$issue->{labels} // []};
}

sub gl_has_unresolved_blockers($repo, $iid) {
    my $enc   = _urlencode($repo);
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

sub _repos_header(@repos) { sprintf "\n## Repos\n```\n%s\n```\n", join "\n", @repos }

sub _format_mr($mr) {
    sprintf "!%d\t%s\t%s\t(main) ← (%s)",
      $mr->{iid}, $mr->{references}{full}, $mr->{title}, $mr->{source_branch};
}

sub _mr_block($repo, @mrs) {
    sprintf "### %s\n```\n%s\n```\n", $repo, join "\n", map { _format_mr($_) } @mrs;
}

sub _section($header, $body) {
    $body =~ /\S/ ? "\n## $header\n$body\n" : '';
}

sub _repo_block($repo, $text) {
    return '' unless $text && $text =~ /\S/;
    $text =~ s/\s+\z//;
    "### $repo\n```\n$text\n```\n";
}

# ---------------------------------------------------------------------------
# Prompt builders
# ---------------------------------------------------------------------------

sub dev_prompt(@repos) {
    my $out = _repos_header(@repos);

    my $mine = '';
    for my $repo (@repos) {
        my $t = gl_issues($repo, '--label', "agent::$ENV{HOSTNAME}");
        $mine .= _repo_block($repo, $t) if $t =~ /^#/m;
    }
    $out .= _section('My in-progress issues', $mine);

    my $ready = '';
    for my $repo (@repos) {
        my $t = gl_issues(
            $repo, '--label', 'workflow::ready for development',
                   '--label', "model::$ENV{ANTHROPIC_MODEL}",
        );
        next unless $t =~ /^#/m;
        my $filtered = join "\n", grep {
                 /^#(\d+)/
              && !gl_is_claimed($repo, $1)
              && !gl_has_unresolved_blockers($repo, $1)
        } split /\n/, $t;
        $ready .= _repo_block($repo, $filtered);
    }
    $out .= _section('Issues ready for dev', $ready);

    my %excl = map { $_ => 1 } 'workflow::in review', 'workflow::in dev';
    my ($ci_fail, $conflicts, $needs_work) = ('', '', '');
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo, "model::$ENV{ANTHROPIC_MODEL}");
        my @f   = grep { ($_->{head_pipeline}{status} // '') eq 'failed' } @$mrs;
        my @c   = grep { $_->{has_conflicts} } @$mrs;
        my @w   = grep { !$_->{has_conflicts} && !grep { $excl{$_} } @{$_->{labels}} } @$mrs;
        $ci_fail    .= _mr_block($repo, @f) if @f;
        $conflicts  .= _mr_block($repo, @c) if @c;
        $needs_work .= _mr_block($repo, @w) if @w;
    }
    $out .= _section('MRs with failed CI', $ci_fail);
    $out .= _section('MRs with conflicts',  $conflicts);
    $out .= _section('MRs needing work',    $needs_work);
    $out;
}

sub lead_prompt(@repos) {
    my $out = _repos_header(@repos);

    my $wake = '';
    for my $repo (@repos) {
        my $t = gl_issues($repo, '--label', 'wake::lead-review');
        $wake .= _repo_block($repo, $t) if $t =~ /^#/m;
    }
    $out .= _section('Issues needing lead review (dev wake-up)', $wake);

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
    );
    my $planning = '';
    for my $repo (@repos) {
        my $t = gl_issues($repo, @not_labels);
        $planning .= _repo_block($repo, $t) if $t =~ /^#/m;
    }
    $out .= _section('Issues needing planning', $planning);
    $out;
}

sub dx_prompt(@repos) {
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
    dev  => { label => 'Iteration',         idle => 'Nothing to do, sleeping',        idle_sleep => TIMEOUT_INTERVAL, prompt => \&dev_prompt  },
    lead => { label => 'Planner iteration',  idle => 'No unrefined issues, sleeping',  idle_sleep => TIMEOUT_INTERVAL, prompt => \&lead_prompt },
    dx   => { label => 'DX audit',          idle => 'No analysis needed, sleeping',   idle_sleep => SLEEP_INTERVAL,   prompt => \&dx_prompt   },
);

sub run_loop($role, $prompt_file, $dry_run) {
    my @repos = gl_repos();
    if ($dry_run) { print $role->{prompt}->(@repos); return }

    require File::Temp;
    my $sys     = File::Temp->new(UNLINK => 1, SUFFIX => '.md');
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

        @repos = gl_repos();
        my $prompt = $role->{prompt}->(@repos);

        unless ($prompt =~ /^## [^R]/m) {
            print "--- $role->{idle} ---\n";
            sleep $role->{idle_sleep};
            next;
        }

        my ($output, $has_sleep) = ('', 0);
        open my $pipe, '-|',
          'claude', '-p', $prompt,
          '--system-prompt-file',      $syspath,
          '--verbose',                 '--dangerously-skip-permissions',
          '--output-format',           'stream-json',
          '--include-partial-messages'
          or do { warn "Failed to launch claude: $!\n"; sleep TIMEOUT_INTERVAL; next };

        while (my $line = <$pipe>) {
            print $line;
            $output .= $line;
            $has_sleep = 1 if $line =~ m{<sleep/>};
        }
        close $pipe;

        die "FATAL: Auth failure — token expired or invalid. Exiting.\n"
          if $output =~ /OAuth token has expired|token.*expired|HTTP 401|API Error: 401|authentication_error/;

        if ($has_sleep) { print "--- Sleeping ---\n"; sleep SLEEP_INTERVAL }
        else            { sleep TIMEOUT_INTERVAL }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

my $dry_run = 0;

GetOptions('dry-run|n' => \$dry_run) or die "Usage: ralph [--dry-run|-n] <dev|lead|dx>\n";

my $cmd  = shift @ARGV // die "Usage: ralph [--dry-run|-n] <dev|lead|dx>\n";
my $role = $ROLES{$cmd}             // die "Unknown command: $cmd\n";

run_loop($role, PROMPT_DIR . "/prompt-${cmd}.md", $dry_run);
