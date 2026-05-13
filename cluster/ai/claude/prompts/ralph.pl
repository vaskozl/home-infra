#!/usr/bin/perl
# ralph — Usage: ralph [--dry-run|-n] <dev|lead|reviewer|dx>
#
# Session model: one persistent claude TUI per pod, driven through a tmux
# session. Ralph spawns claude once and injects each iteration's prompt via
# `tmux send-keys`; a Stop hook (configured in ~/.claude/settings.json) signals
# turn completion by writing one line to /run/claude/turn.fifo. Iterations
# share one conversation — context resets are managed by `/clear` (soft cap)
# and full tmux respawn (hard reset).
use v5.38;
no warnings 'experimental';
binmode STDOUT, ':utf8';
use Errno         qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl         qw(O_RDWR O_NONBLOCK);
use Getopt::Long  qw(GetOptions);
use IO::Select;
use Mojo::File    qw(path);
use Mojo::JSON    qw(decode_json);
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util    qw(url_escape);
use POSIX         qw(mkfifo :sys_wait_h);

use constant PROMPT_DIR           => '/etc/claude';
use constant COMMON_PROMPT        => PROMPT_DIR . '/prompt-common.md';
use constant SLEEP_INTERVAL       => $ENV{SLEEP_INTERVAL}       // 300;
use constant TIMEOUT_INTERVAL     => $ENV{TIMEOUT_INTERVAL}     // 60;
use constant INPUT_TOKEN_SOFT_CAP => $ENV{INPUT_TOKEN_SOFT_CAP} // 80_000;
use constant STOP_TIMEOUT         => $ENV{STOP_TIMEOUT}         // 600;
use constant CLEAR_TIMEOUT        => $ENV{CLEAR_TIMEOUT}        // 30;
use constant CLAUDE_BOOT_DELAY    => $ENV{CLAUDE_BOOT_DELAY}    // 5;
use constant TMUX_SOCKET          => $ENV{TMUX_SOCKET}          // 'claude';
use constant TMUX_SESSION         => $ENV{TMUX_SESSION}         // 'ralph';
use constant TURN_FIFO            => $ENV{TURN_FIFO}            // '/run/claude/turn.fifo';
use constant CLAUDE_BIN           => $ENV{CLAUDE_BIN}           // 'claude';
use constant AUTH_FAIL_RE         =>
    qr/OAuth token has expired|token.*expired|HTTP 401|API Error: 401|authentication_error/i;

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

# ---------------------------------------------------------------------------
# tmux supervisor
# ---------------------------------------------------------------------------
#
# Layout:
#   - One tmux session per pod (-L $TMUX_SOCKET, named $TMUX_SESSION) hosting
#     a long-lived interactive `claude` TUI.
#   - One FIFO at TURN_FIFO. The Stop hook writes one JSON line per turn end.
#     The supervisor keeps it open O_RDWR so writers never block on open and
#     reads never return EOF.
#   - Per-iteration: feed prompt via `tmux load-buffer` + `paste-buffer` +
#     `send-keys Enter`, wait on FIFO for the Stop event, parse the transcript
#     for the last assistant message, update pacing + token counters.

sub _tmux (@args) {
    system('tmux', '-L', TMUX_SOCKET, @args) == 0;
}

sub _tmux_capture () {
    open my $fh, '-|',
      'tmux', '-L', TMUX_SOCKET,
      'capture-pane', '-p', '-t', TMUX_SESSION, '-S', '-200'
      or return '';
    local $/;
    <$fh> // '';
}

sub _ensure_fifo () {
    my $p = TURN_FIFO;
    (my $dir = $p) =~ s{/[^/]+$}{};
    mkdir $dir unless -d $dir;
    return 1 if -p $p;
    unlink $p if -e $p;
    mkfifo($p, 0600) or die "mkfifo $p: $!\n";
    1;
}

sub _open_fifo () {
    _ensure_fifo();
    sysopen(my $fh, TURN_FIFO, O_RDWR | O_NONBLOCK)
      or die "open " . TURN_FIFO . ": $!\n";
    $fh;
}

sub _tmux_session_exists () {
    system('tmux', '-L', TMUX_SOCKET, 'has-session',
        '-t', TMUX_SESSION) == 0;
}

sub _kill_tmux_session () {
    return unless _tmux_session_exists();
    _tmux('kill-session', '-t', TMUX_SESSION);
}

sub _spawn_tmux_session () {
    # Idempotent: leave a running session alone (allows ralph respawn without
    # interrupting a long-running claude).
    return if _tmux_session_exists();

    my $bin = CLAUDE_BIN;
    # Env vars are set on the container in sts.yaml, but re-export them here so
    # that local invocation (no Kubernetes) also suppresses telemetry/updates.
    # Names verified against claude 2.1.113 (see comment in sts.yaml).
    my $cmd = qq{exec env DISABLE_TELEMETRY=1 DISABLE_BUG_COMMAND=1 }
        . qq{DISABLE_AUTOUPDATER=1 DISABLE_ERROR_REPORTING=1 }
        . qq{DISABLE_AUTO_COMPACT=1 }
        . qq{$bin --dangerously-skip-permissions};

    _tmux('new-session', '-d', '-s', TMUX_SESSION,
        '-x', '200', '-y', '50', $cmd)
      or die "Failed to spawn tmux session\n";
    sleep CLAUDE_BOOT_DELAY;
}

sub _enqueue_prompt ($prompt) {
    # load-buffer reads from stdin; paste-buffer dumps into the pane; the
    # trailing Enter submits. Going through a buffer avoids send-keys'
    # literal-text quoting traps (newlines, $, `, etc).
    open my $w, '|-',
      'tmux', '-L', TMUX_SOCKET, 'load-buffer', '-'
      or die "tmux load-buffer: $!\n";
    print $w $prompt;
    close $w or die "tmux load-buffer failed (exit @{[$? >> 8]})\n";

    _tmux('paste-buffer', '-d', '-t', TMUX_SESSION)
      or die "tmux paste-buffer failed\n";
    _tmux('send-keys', '-t', TMUX_SESSION, 'Enter')
      or die "tmux send-keys failed\n";
}

# Block until the next newline-delimited Stop event on the FIFO, or until
# $timeout seconds elapse. Returns the decoded hash, or undef on timeout.
sub _await_stop ($fifo, $timeout) {
    my $sel = IO::Select->new($fifo);
    my $deadline = time + $timeout;
    my $buf = '';
    while (time < $deadline) {
        my $remain = $deadline - time;
        my @ready  = $sel->can_read($remain);
        next unless @ready;
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

# Read the JSONL transcript and return the last assistant message entry (or
# undef). Each entry on disk looks like:
#   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}],
#    "usage":{...}}, ...}
sub _last_assistant_entry ($transcript_path) {
    return undef unless $transcript_path && -r $transcript_path;
    my @lines = path($transcript_path)->lines({ binmode => ':encoding(UTF-8)' });
    for my $line (reverse @lines) {
        my $e = eval { decode_json($line) } or next;
        return $e if ($e->{type} // '') eq 'assistant';
    }
    undef;
}

sub _assistant_text ($entry) {
    return '' unless $entry && ref $entry->{message} eq 'HASH';
    my $content = $entry->{message}{content} // [];
    join '', map { $_->{text} // '' }
      grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' }
      @$content;
}

sub _entry_input_tokens ($entry) {
    my $u = ref $entry eq 'HASH' && ref $entry->{message} eq 'HASH'
      ? $entry->{message}{usage} : undef;
    return 0 unless ref $u eq 'HASH';
    ($u->{input_tokens} // 0)
      + ($u->{cache_creation_input_tokens} // 0)
      + ($u->{cache_read_input_tokens}     // 0);
}

sub run_loop ($role, $prompt_file, $dry_run) {
    my @repos = gl_repos;
    if ($dry_run) { print $role->{prompt}->(@repos); return }

    # Boot: FIFO + tmux + claude. Once per pod lifetime.
    my $fifo = _open_fifo();
    _spawn_tmux_session();

    # Startup jitter — keep pods staggered across the cluster, but only once
    # (iterations no longer cold-start claude).
    my ($ord) = ($ENV{HOSTNAME} // '') =~ /(\d+)$/;
    sleep(($ord // 0) * 240 + int rand 60);

    my $i              = 0;
    my $input_tokens   = 0;       # cumulative since last /clear (or session start)

    while (1) {
        $i++;
        chomp(my $ts = qx(date -Iseconds));
        printf "=== %s %d — %s (tok=%d) ===\n",
          $role->{label}, $i, $ts, $input_tokens;

        # Detect hard failure: tmux session gone (claude crashed, OOM, etc).
        unless (_tmux_session_exists()) {
            warn "tmux session missing; respawning\n";
            $input_tokens = 0;
            _spawn_tmux_session();
        }

        @repos = gl_repos;
        my $prompt = $role->{prompt}->(@repos);

        unless ($prompt =~ /^## (?!Repos\b)/m) {
            print "--- $role->{idle} ---\n";
            sleep $role->{idle_sleep};
            next;
        }

        # Soft-cap context reset BEFORE the next turn — keeps the invariant
        # strict (don't issue another turn over an already-bloated context).
        if ($input_tokens >= INPUT_TOKEN_SOFT_CAP) {
            printf "--- soft cap crossed (%d >= %d); /clear ---\n",
              $input_tokens, INPUT_TOKEN_SOFT_CAP;
            _tmux('send-keys', '-t', TMUX_SESSION, '/clear', 'Enter');
            my $cleared = _await_stop($fifo, CLEAR_TIMEOUT);
            if (!$cleared) {
                warn "no Stop after /clear within ${\ CLEAR_TIMEOUT }s; hard reset\n";
                _kill_tmux_session();
                _spawn_tmux_session();
            }
            $input_tokens = 0;
        }

        _enqueue_prompt($prompt);
        my $stop = _await_stop($fifo, STOP_TIMEOUT);

        if (!$stop) {
            warn "turn timeout (${\ STOP_TIMEOUT }s) — hard reset\n";
            _kill_tmux_session();
            _spawn_tmux_session();
            $input_tokens = 0;
            sleep TIMEOUT_INTERVAL;
            next;
        }

        my $entry = _last_assistant_entry($stop->{transcript_path});
        my $body  = _assistant_text($entry);
        $input_tokens += _entry_input_tokens($entry);

        # Print a short preview so pod logs still tell us what happened.
        if (length $body) {
            my $preview = substr $body, 0, 400;
            $preview =~ s/\n/\\n/g;
            print "--- assistant: $preview", (length $body > 400 ? '…' : ''), "\n";
        }

        # Rate-limit: check transcript body and tmux pane for 429 markers.
        my $pane    = _tmux_capture();
        my $is_429  = ($body =~ /\b429\b|rate[\s_-]?limit/i)
                   || ($pane =~ /\b429\b|rate[\s_-]?limit/i);

        die "FATAL: Auth failure — token expired or invalid. Exiting.\n"
          if $body =~ AUTH_FAIL_RE || $pane =~ AUTH_FAIL_RE;

        if ($is_429) {
            warn "Rate-limited (429); sleeping\n";
            sleep SLEEP_INTERVAL;
            next;
        }

        if ($body =~ m{<sleep/>}) {
            print "--- Sleeping ---\n";
            sleep SLEEP_INTERVAL;
        }
        else {
            sleep TIMEOUT_INTERVAL;
        }
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
