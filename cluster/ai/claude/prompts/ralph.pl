#!/usr/bin/perl
# ralph: Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx>
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
use constant CLAUDE_BIN        => $ENV{CLAUDE_BIN}        // 'claude';
use constant CLAUDE_MD         => ($ENV{HOME} // '/home/nonroot') . '/.claude/CLAUDE.md';
use constant IGNORE_TITLE_RE   => qr/renovate dashboard/i;

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
    my $data = eval { decode_json(_run('glab', 'repo', 'list', '-a', '--output', 'json')) };
    $data ? map { $_->{path_with_namespace} } @$data : ();
}

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

# Return list of open MR IIDs whose LATEST pipeline failed.
# Iterates pipelines (sorted by created_at DESC) and dedupes by ref to keep
# only each MR's most recent pipeline, avoiding the historical-failure trap
# of filtering by status=failed (which returns every failed pipeline ever).
# Uses the pipelines API rather than the MR list because that endpoint always
# returns head_pipeline: null.
sub gl_failed_mr_iids ($repo) {
    my $enc   = url_escape($repo);
    my $pipes = _gl_api(
        "projects/${enc}/pipelines?source=merge_request_event&per_page=100"
    ) or return ();
    my %latest;
    for my $p (@$pipes) {
        my ($iid) = ($p->{ref} // '') =~ m{^refs/merge-requests/(\d+)/head$} or next;
        $latest{$iid} //= $p->{status};   # first occurrence is newest (sorted DESC)
    }
    grep { ($latest{$_} // '') eq 'failed' } keys %latest;
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Prompt builders
# ---------------------------------------------------------------------------

sub dev_prompt (@repos) {
    my $out = _repos_header(@repos);

    my $mine = '';
    for my $repo (@repos) {
        my @issues = @{gl_issues_api($repo, "agent::$ENV{HOSTNAME}")};
        # Skip issues already in review; dev has nothing to do until human acts.
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
            # Deliberately NOT filtering agent::* here: workflow::in review is the
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

# ---------------------------------------------------------------------------
# tmux supervisor
# ---------------------------------------------------------------------------

sub _tmux (@args) {
    system('tmux', '-L', TMUX_SOCKET, @args) == 0;
}

sub _ensure_fifo () {
    my $p = TURN_FIFO;
    (my $dir = $p) =~ s{/[^/]+$}{};
    path($dir)->make_path;
    return 1 if -p $p;
    unlink $p if -e $p;
    mkfifo($p, 0600) or die "mkfifo $p: $!\n";
    1;
}

# Open the FIFO O_RDWR so writers never block on open and reads never EOF.
sub _open_fifo () {
    _ensure_fifo();
    sysopen(my $fh, TURN_FIFO, O_RDWR | O_NONBLOCK)
      or die "open " . TURN_FIFO . ": $!\n";
    $fh;
}

# Idempotent: succeeds whether or not a session exists. Forks to keep
# tmux's "no such session/server" noise off our stderr.
sub _kill_tmux_session () {
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        open STDERR, '>', '/dev/null';
        exec 'tmux', '-L', TMUX_SOCKET, 'kill-session', '-t', TMUX_SESSION;
        exit 0;
    }
    waitpid $pid, 0;
}

# Write the combined common + role prompt to ~/.claude/CLAUDE.md so claude
# loads role context automatically at startup.
sub _install_claude_md ($cmd) {
    my $out = path(CLAUDE_MD);
    $out->dirname->make_path;
    my $body = path(COMMON_PROMPT)->slurp . "\n" . path(PROMPT_DIR . "/prompt-${cmd}.md")->slurp;
    $out->spew($body);
}

sub _spawn_tmux_session () {
    _tmux('new-session', '-d', '-s', TMUX_SESSION,
        '-e', 'TERM=' . TMUX_TERM,
        '-e', 'LANG=C.UTF-8',
        '-e', 'LC_ALL=C.UTF-8',
        '-x', TMUX_WIDTH, '-y', TMUX_HEIGHT,
        'exec ' . CLAUDE_BIN . ' --dangerously-skip-permissions')
      or die "Failed to spawn tmux session\n";
    # Pin the window: attaching clients otherwise resize claude's viewport.
    _tmux('set-option', '-t', TMUX_SESSION, 'window-size', 'manual');
    sleep CLAUDE_BOOT_DELAY;
    # First-run workspace-trust prompt: press Enter to accept. If no prompt
    # is shown, the empty submit is a no-op.
    _tmux('send-keys', '-t', TMUX_SESSION, 'Enter');
    sleep 1;
}

sub _restart_tmux_session () {
    _kill_tmux_session();
    _spawn_tmux_session();
}

# load-buffer + paste-buffer avoids send-keys' literal-text quoting traps
# (newlines, $, `, etc); trailing Enter submits the turn.
sub _enqueue_prompt ($prompt) {
    open my $w, '|-',
      'tmux', '-L', TMUX_SOCKET, 'load-buffer', '-'
      or die "tmux load-buffer: $!\n";
    binmode $w, ':encoding(UTF-8)';
    print $w $prompt;
    close $w or die "tmux load-buffer failed (exit @{[$? >> 8]})\n";

    _tmux('paste-buffer', '-d', '-t', TMUX_SESSION)
      or die "tmux paste-buffer failed\n";
    sleep 1;
    _tmux('send-keys', '-t', TMUX_SESSION, 'Enter')
      or die "tmux send-keys failed\n";
}

# Block until the next newline-delimited Stop event on the FIFO, or until
# $timeout seconds elapse. Returns the decoded hash, or undef on timeout.
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
            return undef;
        }
        next if $n == 0;
        if ((my $nl = index $buf, "\n") >= 0) {
            my $line = substr $buf, 0, $nl;
            return eval { decode_json($line) } || { evt => 'stop' };
        }
    }
    undef;
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
        _restart_tmux_session();
        _enqueue_prompt($prompt);
        my $stop = _await_stop($fifo, STOP_TIMEOUT);
        _kill_tmux_session();

        warn "turn timeout (${\ STOP_TIMEOUT }s)\n" unless $stop;
        sleep TIMEOUT_INTERVAL;
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

run_loop($role, $cmd, $dry_run);
