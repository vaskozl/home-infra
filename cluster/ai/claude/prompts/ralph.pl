#!/usr/bin/perl
# ralph: Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx|ops>
#
# Drives one claude TUI per iteration through a tmux session. The role's
# work list is piped in as a single user turn; a Stop hook writes one line
# to /run/claude/turn.fifo when the turn finishes. Each iteration kills and
# respawns tmux so claude starts with a clean context.
use v5.38;
no warnings 'experimental';
binmode STDOUT, ':utf8';
use Errno         qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl         qw(O_RDWR O_NONBLOCK);
use Getopt::Long  qw(GetOptions);
use IO::Select;
use Mojo::File    qw(path);
use Mojo::JSON    qw(decode_json);
use Mojo::UserAgent;
use Mojo::Util    qw(url_escape);
use POSIX         qw(mkfifo strftime);

use constant PROMPT_DIR        => '/etc/claude';
use constant COMMON_PROMPT     => PROMPT_DIR . '/prompt-common.md';
use constant SLEEP_INTERVAL    => $ENV{SLEEP_INTERVAL}    // 300;
use constant TIMEOUT_INTERVAL  => $ENV{TIMEOUT_INTERVAL}  // 60;
use constant STOP_TIMEOUT      => $ENV{STOP_TIMEOUT}      // 7200;
use constant CLAUDE_BOOT_DELAY => $ENV{CLAUDE_BOOT_DELAY} // 5;
use constant TMUX_SOCKET       => $ENV{TMUX_SOCKET}       // 'claude';
use constant TMUX_SESSION      => $ENV{TMUX_SESSION}      // 'ralph';
use constant TMUX_WIDTH        => $ENV{TMUX_WIDTH}        // 120;
use constant TMUX_HEIGHT       => $ENV{TMUX_HEIGHT}       // 32;
use constant TMUX_TERM         => $ENV{TMUX_TERM}         // 'xterm-256color';
use constant TURN_FIFO         => $ENV{TURN_FIFO}         // '/run/claude/turn.fifo';
use constant PROMPT_FILE       => $ENV{PROMPT_FILE}       // '/run/claude/prompt.md';
use constant CLAUDE_BIN        => $ENV{CLAUDE_BIN}        // 'claude';
use constant CLAUDE_MD         => ($ENV{HOME} // '/home/nonroot') . '/.claude/CLAUDE.md';
use constant IGNORE_TITLE_RE   => qr/renovate dashboard/i;
use constant ALERTMANAGER_URL  => $ENV{ALERTMANAGER_URL};
use constant OPS_SNOOZE        => $ENV{OPS_SNOOZE_DURATION} // 3600;
use constant OPS_BRANCH_RE     => qr{^claude-ops(?:-\d+)?/};
use constant OPS_AGENT_LABEL   => "agent::$ENV{HOSTNAME}";
use constant OPS_FP_RE         => qr/`([a-f0-9]{16})`/;

my $ua = Mojo::UserAgent->new->request_timeout(30);
$ua->on(start => sub ($ua, $tx) {
    $tx->req->headers->header('PRIVATE-TOKEN' => $ENV{GITLAB_TOKEN});
});
my $API_BASE = ($ENV{GITLAB_HOST} // 'https://gitlab.sko.ai') . '/api/v4';

sub _gl_api ($path) {
    my $res = eval { $ua->get("$API_BASE/$path")->result } or return;
    return unless $res->is_success;
    eval { $res->json };
}

sub _run (@cmd) {
    open my $fh, '-|', @cmd or return '';
    local $/;
    <$fh> // '';
}

sub gl_repos () {
    my $data = eval { decode_json(_run('glab', 'repo', 'list', '-a', '--output', 'json')) };
    $data ? map { $_->{path_with_namespace} } @$data : ();
}

sub gl_issues ($repo, @args) {
    my $out = _run('glab', 'issue', 'list', '-R', $repo, @args);
    join "\n", grep { $_ !~ IGNORE_TITLE_RE } split /\n/, $out;
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

# Dedup pipelines by MR ref to keep each MR's *latest* one — filtering by
# status=failed instead returns every historical failure. The MR-list
# endpoint can't substitute here: it returns head_pipeline: null.
sub gl_failed_mr_iids ($repo) {
    my $enc   = url_escape($repo);
    my $pipes = _gl_api(
        "projects/${enc}/pipelines?source=merge_request_event&per_page=100"
    ) or return;
    my %latest;
    for my $p (@$pipes) {
        my ($iid) = ($p->{ref} // '') =~ m{^refs/merge-requests/(\d+)/head$} or next;
        $latest{$iid} //= $p->{status};   # API returns newest-first
    }
    grep { ($latest{$_} // '') eq 'failed' } keys %latest;
}

sub _repos_header (@repos) {
    sprintf "\n## Repos\n```\n%s\n```\n", join "\n", @repos;
}

sub _format_mr ($mr) {
    my ($wf)    = grep { /^workflow::/ } @{$mr->{labels} // []};
    my ($agent) = grep { /^agent::/    } @{$mr->{labels} // []};
    my $wf_str  = $wf ? ($wf =~ s/^workflow:://r) : 'no-workflow';
    my $tag     = $agent ? " [$wf_str, $agent]" : " [$wf_str]";
    sprintf "!%d\t%s\t%s\t(main) \x{2190} (%s)%s",
      $mr->{iid}, $mr->{references}{full}, $mr->{title}, $mr->{source_branch}, $tag;
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

sub dev_prompt (@repos) {
    my $out = _repos_header(@repos);

    my $mine = '';
    for my $repo (@repos) {
        my @issues = @{gl_issues_api($repo, "agent::$ENV{HOSTNAME}")};
        # Skip in-review issues: dev has nothing to do until a human acts.
        @issues = grep {
            !grep { $_ eq 'workflow::in review' } @{$_->{labels} // []}
        } @issues;
        next unless @issues;
        my $text = join "\n", map { sprintf "#%d\t%s", $_->{iid}, $_->{title} } @issues;
        $mine .= _repo_block($repo, $text);
    }
    $out .= _section('My in-progress issues', $mine);

    my $my_mrs = '';
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo, "agent::$ENV{HOSTNAME}", "workflow::in dev");
        $my_mrs .= _mr_block($repo, @$mrs) if @$mrs;
    }
    $out .= _section('My in-progress MRs', $my_mrs);

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

    my %excl = map { $_ => 1 } 'workflow::in review', 'workflow::in dev';
    my ($ci_fail, $conflicts, $needs_work) = ('', '', '');
    for my $repo (@repos) {
        my $mrs  = gl_open_mrs($repo, "model::$ENV{ANTHROPIC_MODEL}");
        my %open = map { $_->{iid} => $_ } @$mrs;
        my @f    = map { $open{$_} // () } gl_failed_mr_iids($repo);
        my @c    = grep { $_->{has_conflicts} } @$mrs;
        my @w    = grep {
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
        my $enc    = url_escape($repo);
        my $mrs    = gl_open_mrs($repo);
        my %failed = map { $_ => 1 } gl_failed_mr_iids($repo);
        my (@r, @ren);
        for my $mr (@$mrs) {
            my @labels = @{$mr->{labels} // []};
            next if grep { $_ eq 'claude::ignore' || $_ eq 'review::deferred' } @labels;
            next if $failed{$mr->{iid}};
            my $is_renovate = ($mr->{source_branch} // '') =~ m{^renovate/};
            my $in_review   = grep { $_ eq 'workflow::in review' } @labels;
            next unless $is_renovate || $in_review;
            # No agent::* filter here: workflow::in review is the authoritative
            # "dev is done" signal; multi-reviewer races are handled by the
            # 10s verify-on-claim.
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
    my $ts  = strftime("%FT%T%z", localtime);
    $out .= "\n## DX audit ($ts)\n";
    $out .= <<'END';
Agent logs live at /logs/ai/ on the ripgrep pod.
Each line: <JSON> pod=<pod> ctr=<ctr> ts=<ts>; strip trailing fields before piping to jq:

```bash
# Recent agent sessions (result lines carry cost, turns, outcome)
kubectl exec -n logging ripgrep-0 -- rg '"type":"result"' /logs/ai/claude-worker-sonnet.log | \
  tail -20 | sed 's/ pod=[^ ]* ctr=[^ ]* ts=[^ ]*//' | \
  jq '{pod: .session_id, cost: .total_cost_usd, turns: .num_turns, ok: (.is_error | not), preview: .result[:120]}'
```
END
    $out;
}

# ── ops role ──────────────────────────────────────────────────────────────
# Alert-driven counterpart to the other roles: work comes from Alertmanager
# active alerts plus our own open `claude-ops/*` MRs, not GitLab issues.
#
# Snooze: fingerprints we've already shown claude that produced no MR are
# suppressed for OPS_SNOOZE seconds so we don't re-present them every loop.
# Entries clear when the alert stops firing (a re-fire deserves a fresh look).
my %ops_snoozed;          # fp → expiry epoch
my @ops_last_presented;   # fps shown to claude in the previous iteration

sub am_alerts () {
    my $base = ALERTMANAGER_URL // return [];
    $base =~ s{/+$}{};
    my $res = eval {
        $ua->get("$base/api/v2/alerts?active=true&silenced=false&inhibited=false")->result
    } or return [];
    return [] unless $res->is_success;
    [ grep { ($_->{status}{state} // '') eq 'active' } @{ $res->json // [] } ];
}

sub _ops_mrs (@repos) {
    my @out;
    for my $repo (@repos) {
        my $mrs = gl_open_mrs($repo);
        for my $mr (@$mrs) {
            next unless ($mr->{source_branch} // '') =~ OPS_BRANCH_RE;
            push @out, { %$mr, _repo => $repo };
        }
    }
    @out;
}

sub _ops_known_fps (@mrs) {
    my %fp;
    for my $mr (@mrs) {
        my $d = $mr->{description} // '';
        $fp{$1} = 1 while $d =~ /@{[ OPS_FP_RE ]}/g;
    }
    \%fp;
}

# rework: human pulled `workflow::in review` to request changes — act first.
# in-flight: still tagged `agent::claude-ops` — orphaned mid-work, resume.
# in-review: handed off to humans — don't touch.
sub _ops_classify ($mr) {
    my @l = @{ $mr->{labels} // [] };
    return 'in-review' if grep { $_ eq 'workflow::in review' } @l;
    return 'in-flight' if grep { $_ eq OPS_AGENT_LABEL } @l;
    'rework';
}

sub _first_line ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    (split /\n/, $s, 2)[0] // '';
}

sub _format_alert ($a) {
    my $L = $a->{labels}      // {};
    my $A = $a->{annotations} // {};
    my $out = sprintf "[%s] %s  fp=%s\n",
      ($L->{severity} // ''), ($L->{alertname} // ''), ($a->{fingerprint} // '');
    my @lp = map "$_=$L->{$_}",
      sort grep { $_ ne 'alertname' && $_ ne 'severity' } keys %$L;
    $out .= "  labels: " . join(' ', @lp) . "\n" if @lp;
    my $sum = _first_line($A->{summary});
    my $dsc = _first_line($A->{description});
    $out .= "  summary: $sum\n"               if length $sum;
    $out .= "  description: $dsc\n"           if length $dsc && $dsc ne $sum;
    $out .= "  runbook: $A->{runbook_url}\n"  if $A->{runbook_url};
    $out .= "  generator: $a->{generatorURL}\n" if $a->{generatorURL};
    $out;
}

sub _ops_mr_section ($header, $note, @mrs) {
    return '' unless @mrs;
    my %by_repo;
    push @{ $by_repo{ $_->{_repo} } }, $_ for @mrs;
    my $body = join '',
      map { _mr_block($_, @{ $by_repo{$_} }) } sort keys %by_repo;
    "\n## $header\n$note\n$body";
}

sub ops_prompt (@repos) {
    my $now = time;

    # Expire old snoozes.
    delete $ops_snoozed{$_} for grep { $ops_snoozed{$_} <= $now } keys %ops_snoozed;

    my $alerts = am_alerts();
    my @mrs    = _ops_mrs(@repos);
    my $known  = _ops_known_fps(@mrs);

    # Deferred snooze: any fp shown last round still without an MR → claude
    # saw it and chose not to act. Snooze so we stop nagging.
    for my $fp (@ops_last_presented) {
        $ops_snoozed{$fp} = $now + OPS_SNOOZE unless $known->{$fp};
    }
    @ops_last_presented = ();

    # Clear snoozes for alerts no longer firing — a re-fire gets fresh eyes.
    my %active = map { ($_->{fingerprint} // '') => 1 } @$alerts;
    delete $ops_snoozed{$_} for grep { !$active{$_} } keys %ops_snoozed;

    my (@rework, @inflight, @inreview);
    for my $mr (@mrs) {
        my $c = _ops_classify($mr);
        push @rework,   $mr if $c eq 'rework';
        push @inflight, $mr if $c eq 'in-flight';
        push @inreview, $mr if $c eq 'in-review';
    }

    my @fresh;
    for my $a (@$alerts) {
        my $fp = $a->{fingerprint} // next;
        next if $known->{$fp} || $ops_snoozed{$fp};
        push @fresh, $a;
    }
    @ops_last_presented = map { $_->{fingerprint} } @fresh;

    my $out = _repos_header(@repos);
    $out .= _ops_mr_section('MRs needing rework',
        "No `workflow::in review` label — a human removed it to request changes. Address these first.",
        @rework);
    $out .= _ops_mr_section("MRs in flight (@{[ OPS_AGENT_LABEL ]})",
        "Orphaned from a previous iteration. Resume and hand off to review.",
        @inflight);
    $out .= _ops_mr_section('MRs awaiting review (workflow::in review)',
        "Already handed off; do not touch unless a human removes the label.",
        @inreview);

    if (@fresh) {
        $out .= "\n## Active alerts\n"
              . "Skip any alert whose fingerprint already appears in an MR description above.\n"
              . join("\n", map { _format_alert($_) } @fresh) . "\n";
    }
    $out;
}

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
    ops => {
        label      => 'Ops iteration',
        idle       => 'No fresh alerts and no MRs needing attention, sleeping',
        idle_sleep => TIMEOUT_INTERVAL,
        prompt     => \&ops_prompt
    },
);

sub _tmux (@args) {
    system('tmux', '-L', TMUX_SOCKET, @args) == 0;
}

sub _ensure_fifo () {
    my $p = TURN_FIFO;
    (my $dir = $p) =~ s{/[^/]+$}{};
    path($dir)->make_path;
    return if -p $p;
    unlink $p if -e $p;
    mkfifo($p, 0600) or die "mkfifo $p: $!\n";
}

# O_RDWR: writers never block on open; reader never sees EOF.
sub _open_fifo () {
    _ensure_fifo();
    sysopen(my $fh, TURN_FIFO, O_RDWR | O_NONBLOCK)
      or die "open " . TURN_FIFO . ": $!\n";
    $fh;
}

# Idempotent. Forks so tmux's "no such session" message stays off our stderr.
sub _kill_tmux_session () {
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        open STDERR, '>', '/dev/null';
        exec 'tmux', '-L', TMUX_SOCKET, 'kill-session', '-t', TMUX_SESSION;
        exit 0;
    }
    waitpid $pid, 0;
}

# Combined common+role prompt; claude loads it as CLAUDE.md at startup.
sub _install_claude_md ($cmd) {
    my $out = path(CLAUDE_MD);
    $out->dirname->make_path;
    my $body = path(COMMON_PROMPT)->slurp . "\n" . path(PROMPT_DIR . "/prompt-${cmd}.md")->slurp;
    $out->spew($body);
}

# Passing the prompt via "$(cat FILE)" inside double quotes is a literal
# expansion — no further word-splitting or metachar parsing — so backticks,
# $, newlines, etc. in the prompt survive intact.
sub _spawn_tmux_session ($prompt) {
    my $f = path(PROMPT_FILE);
    $f->dirname->make_path;
    open my $fh, '>:encoding(UTF-8)', $f or die "open $f: $!\n";
    print $fh $prompt;
    close $fh or die "close $f: $!\n";

    _tmux('new-session', '-d', '-s', TMUX_SESSION,
        '-e', 'TERM=' . TMUX_TERM,
        '-e', 'LANG=C.UTF-8',
        '-e', 'LC_ALL=C.UTF-8',
        '-x', TMUX_WIDTH, '-y', TMUX_HEIGHT,
        sprintf('exec %s --dangerously-skip-permissions "$(cat %s)"',
                CLAUDE_BIN, PROMPT_FILE))
      or die "Failed to spawn tmux session\n";
    # Pin the window so attaching clients don't resize claude's viewport.
    _tmux('set-option', '-t', TMUX_SESSION, 'window-size', 'manual');
    sleep CLAUDE_BOOT_DELAY;
    # Dismiss the first-run workspace-trust prompt (no-op if absent).
    _tmux('send-keys', '-t', TMUX_SESSION, 'Enter');
}

sub _restart_tmux_session ($prompt) {
    _kill_tmux_session();
    _spawn_tmux_session($prompt);
}

sub _await_stop ($fifo, $timeout) {
    my $sel      = IO::Select->new($fifo);
    my $deadline = time + $timeout;
    my $buf      = '';
    while (time < $deadline) {
        my $remain = $deadline - time;
        my @ready  = $sel->can_read($remain);
        last unless @ready;
        my $n = sysread $fifo, $buf, 8192, length $buf;
        if (!defined $n) {
            next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
            warn "FIFO sysread: $!\n";
            return;
        }
        next if $n == 0;
        if ((my $nl = index $buf, "\n") >= 0) {
            my $line = substr $buf, 0, $nl;
            return eval { decode_json($line) } || { evt => 'stop' };
        }
    }
    return;
}

sub run_loop ($role, $cmd, $dry_run) {
    my @repos = gl_repos;
    if ($dry_run) { print $role->{prompt}->(@repos); return }

    _install_claude_md($cmd);
    my $fifo = _open_fifo();

    my $i = 0;
    while (1) {
        $i++;
        my $ts = strftime("%FT%T%z", localtime);
        printf "=== %s %d: %s ===\n", $role->{label}, $i, $ts;

        @repos = gl_repos;
        my $prompt = $role->{prompt}->(@repos);

        unless ($prompt =~ /^## (?!Repos\b)/m) {
            print "--- $role->{idle} ---\n";
            sleep $role->{idle_sleep};
            next;
        }

        # Fresh claude every iteration: clean context, no auto-compact games.
        _restart_tmux_session($prompt);
        my $stop = _await_stop($fifo, STOP_TIMEOUT);
        _kill_tmux_session();

        warn "turn timeout (${\ STOP_TIMEOUT }s)\n" unless $stop;
        sleep TIMEOUT_INTERVAL;
    }
}

my $dry_run = 0;

GetOptions('dry-run|n' => \$dry_run)
  or die "Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx|ops>\n";

my $cmd  = shift @ARGV  // die "Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx|ops>\n";
my $role = $ROLES{$cmd} // die "Unknown command: $cmd\n";

run_loop($role, $cmd, $dry_run);
