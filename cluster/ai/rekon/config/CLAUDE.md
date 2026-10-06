## How you run

You run autonomously inside a loop. Each iteration starts with a fresh context,
and the repo you operate on is already checked out clean and up to date on its
default branch (it is prepared for you before you start). A controller has
already selected the single item for this turn (an issue, an MR, or an alert)
and named it in the task prompt: act on that one item and do not go looking for
other work.

Do not ask questions interactively; they will not be answered. Record anything
that needs a human or a future iteration as a GitLab issue or an MR comment.
Missing tools or config issues should be logged as issues (see the table below).

## Environment

You run as `nonroot` (uid 568) on a Wolfi-based container image inside the
`home-infra` Kubernetes cluster (namespace: `ai`). You have read-only access to
the cluster, excluding Secrets, via your pod's service account; use `kubectl`
to inspect workloads, pods, events, and resources across all namespaces.

Your home directory is `/home/nonroot/`. Clone repos here (e.g.,
`/home/nonroot/<repo>`). **Do not** use `/root/`; it is not accessible to uid
568.

If something is wrong or missing, fix it temporarily then log an issue with
`glab issue create -R <repo>` so it gets permanently fixed:

| Problem | Temp fix | Issue repo |
|---|---|---|
| Missing tool / binary or apk package | `brew install <pkg>` | `doudous/apkontainers` (edit `claude.yaml`) |
| Prompt & config issues (unclear/missing instructions in this file) | n/a | `doudous/home-infra` |

An issue meant to be implemented is only picked up with both labels
`workflow::ready for development` and `model::opus`; add them on create
(`-l 'workflow::ready for development' -l 'model::opus'`).

## Shared pod: scratch files and local app runs

Many turns share this pod's filesystem and localhost. Another turn's binary,
server or redis is one `ls /tmp` or `ss -ltnp` away, and yours is visible to
them. Never run or connect to something you did not start in this turn. If
your `cd` or build fails, fix it; a binary that already exists at the path you
meant to write is another turn's.

- **Scratch files**: use `$TMPDIR` (private, wiped with the turn) via
  `mktemp`, `go build -o "$TMPDIR/<app>"`, etc. Never a fixed `/tmp/<name>`.
  `/tmp/screenshots` is the one path that is meant to be shared.
- **Ports**: never bind a fixed port (8080, 6379, 63xx, 5432, 3000...). 9222
  and 9223 belong to the chromium sidecars. Pick a free loopback port and pass
  it explicitly to the app:
  ```bash
  PORT=$(perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(Listen=>1,LocalAddr=>"127.0.0.1",LocalPort=>0) or die; print $s->sockport')
  ```
- **Redis**: start a throwaway one:
  ```bash
  REDIS_PORT=$(perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(Listen=>1,LocalAddr=>"127.0.0.1",LocalPort=>0) or die; print $s->sockport')
  redis-server --bind 127.0.0.1 --port "$REDIS_PORT" --save "" --appendonly no --dir "$TMPDIR" --loglevel warning &
  redis-cli -p "$REDIS_PORT" ping
  ```
  `flushall`, `flushdb`, `shutdown` and `config set` only against a redis you
  started this turn. To reset state, kill yours and start it again (it is
  ephemeral, so a restart is a clean slate). Before touching any redis you did
  not just start, `redis-cli -p <port> config get dir` must print a path under
  your `$TMPDIR`; anything else is another turn's or prod. Do not use
  `redis-master` for testing: it is the prod redis this runner uses. You may
  use it only for debugging issues with the setup.
- **Cleanup**: processes you start are killed when the turn ends, but stop
  your servers when you are done so the port frees up for other turns.

## Metrics access

The victoriametrics MCP server is available for querying cluster metrics, e.g.
to check actual CPU/memory usage before right-sizing a resource limit, or to
confirm an alert is or isn't firing. Don't over-use it; most work needs code and
issue context, not metrics.

## Tech preferences

- **CI / container images**: Use our own `ghcr.io/vaskozl/<name>` chainguard
  images (built from `doudous/apkontainers`) instead of Docker Hub mutable tags
  like `alpine:latest` or `debian:latest`. They're minimal, multi-arch,
  regularly rebuilt for security patches, and we control the contents. If no
  existing image fits, add a new yaml to `doudous/apkontainers` rather than
  reaching for a public mutable tag.
- **Backend code**: Write efficient, lean server side templated pages HTML
  sites. Prefer full-page navigation; it's simpler and correct. For cases that
  genuinely need partial page swaps, use
  [fixi.js](https://github.com/bigskysoftware/fixi) (a light htmx alternative
  that can be vendored) rather than heavier JS frameworks.
- **One-liners**: Reach for `perl` over `python`/`awk`/`sed`; it's always
  available and usually shorter:
  ```bash
  perl -MJSON::XS -lane 'print decode_json($_)->{name}' file.json
  perl -lane 'print $F[2]' file.txt   # awk '{print $3}'
  perl -pe 's/foo/bar/g'              # sed 's/foo/bar/g'
  ```
- **HTTP + JSON**: Mojolicious is installed. Use `ojo` for one-liners and
  `Mojo::UserAgent` / `Mojo::JSON` in scripts; much shorter than `curl | jq` or
  `LWP::UserAgent` + `JSON::PP`:
  ```bash
  # GET + decode JSON response
  perl -Mojo -E 'say r g("https://gitlab.example.com/api/v4/projects")->json->[0]{name}'

  # POST JSON body, extract field via JSON pointer
  perl -Mojo -E 'say p("https://httpbin.org/post" => json => {a => 1})->json("/json/a")'

  # Decode a local JSON file
  perl -Mojo -E 'say j(f("data.json")->slurp)->{key}'
  ```
  See if needed: `perldoc ojo`, `perldoc Mojo::UserAgent`, `perldoc Mojo::JSON`.

## Known tool issues

- **`glab mr list --state`**: Not supported by glab. Use `glab mr list`
  (defaults to open MRs) or query the API: `glab api "projects/$(printf '%s'
  'group/repo' | jq -Rr @uri)/merge_requests?state=opened"`.
- **`glab issue close -c`**: The `-c` flag does not exist. To close an issue
  with a comment, use two separate commands: `glab issue close <id> -R <repo>`
  then `glab issue note <id> -R <repo> -m "..."`.
- **`glab ci status --ref`**: The `--ref` flag does not exist. Use `glab ci
  status -R <repo> -b <branch>` to check a branch, or `glab ci view <mr_iid> -R
  <repo>` for a specific MR's pipeline. There is no flag to query by commit SHA;
  use `glab api "projects/$(printf '%s' 'group/repo' | jq -Rr
  @uri)/repository/commits/<sha>/statuses"` if a SHA-specific lookup is required.
- **`glab mr note -m` / `--resolve`**: Deprecated flags, print a warning on every
  use. Use `glab mr note create <id> -m "..."` (add `--resolvable=false` for
  summary or status comments, otherwise it opens a resolvable thread) and `glab
  mr note resolve <id> <discussion_id>` (MR id first, then discussion id; the
  `--help` usage line shows the reverse and is wrong).
- **`python3`**: Not installed in the container. Use `jq` or `perl` for all
  JSON/text processing.

## glab quick-reference

| Task | Command |
|---|---|
| List open issues | `glab issue list -R <repo>` |
| List open MRs | `glab mr list -R <repo>` |
| View issue details | `glab issue view <id> -R <repo>` |
| View issue as JSON | `glab issue view <id> -R <repo> --output json` |
| Update issue labels | `glab issue update <id> -R <repo> -l 'label-to-add' -u 'label-to-remove'` |
| Update issue description | `glab issue update <id> -R <repo> -d "new description"` |
| Create MR | `glab mr create -d "description" -l 'label'` |
| View MR details | `glab mr view <id> -R <repo>` |
| View MR as JSON | `glab mr view <id> -R <repo> --output json` |
| View MR comments | `glab mr view <id> -R <repo> -c` |
| Add MR comment | `glab mr note create <id> -R <repo> -m "comment" --resolvable=false` |
| Add inline MR diff comment | `glab mr note create <id> -R <repo> --file <path> --line <n> -m "comment"` |
| Resolve MR thread | `glab mr note resolve <id> <discussion_id> -R <repo>` |
| View CI status | `glab ci view <mr_iid> -R <repo>` |
| API query | `glab api "projects/$(printf '%s' 'group/repo' \| jq -Rr @uri)/merge_requests?state=opened"` |

> **glab JSON label format (important)**
> - All `glab --output json` output (issue view/list, mr view/list) returns labels as **plain strings**: `["label1", "label2"]`.
> - Always iterate with `.labels[]`, never `.labels[].name`, which will fail with `Cannot index string with string "name"`.
> - Always add `2>/dev/null` after jq in parallel batches to prevent exit-code cascades from aborting sibling tool calls.

## Code comments

Default to **no comment**. Only add one when the *why* is non-obvious (a hidden
constraint, a workaround for a real bug, behaviour that would surprise a
reader). Never narrate history: no "previously this did X", no "fixed bug where
Y", no MR/issue numbers, no "added for the Z flow". The diff and commit message
carry that context; code comments rot.

Never use em dashes (U+2014) in code, commit messages, or MR descriptions. Use
`--`, a colon, or restructure the sentence.

### Uploading image evidence

Use the chrome-devtools MCP tools to take a screenshot, save it to
`/tmp/screenshots/evidence.png` (a volume shared between the `app`,
`chrome-devtools-mcp` and `chromium` browser containers), upload it to GitLab,
and embed the returned markdown in your MR or issue comment:

```bash
# 1. Upload to GitLab (glab api doesn't support multipart, use curl)
UPLOAD=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --form "file=@/tmp/screenshots/evidence.png" \
  "${GITLAB_HOST}/api/v4/projects/${repo/\//%2F}/uploads")
IMG_MD=$(echo "$UPLOAD" | jq -r '.markdown')
# 2. Use $IMG_MD in a comment
glab mr note create <id> -R <repo> -m "## Evidence
${IMG_MD}"
```

To submit a file through a form `<input type=file>` during web QA, write it
under `/tmp/screenshots` (or `$TMPDIR`, which lives under the shared
`/home/nonroot`) and pass its absolute path to `upload_file`. The browser
process opens the file at submit time, so it must be on a path the `chromium`
container also mounts; anywhere else (e.g. a fixed `/tmp/<name>`) fails at
submit with `net::ERR_FILE_NOT_FOUND`.

## Token arbitrage with codex

Treat Codex as the default execution and research partner, not a last resort.
Invoke it before doing mechanical, verbose, parallelisable, or well-specified
work: web research, code search, long-log/diff/test analysis, security review,
test babysitting, and small implement-until-green changes. Review its output
and diff yourself; keep architecture and final judgement with you.

Tips (verified on codex 0.154):

- Always pass `-c 'model_reasoning_effort="max"'`; use lower effort only when
  latency matters. Set the same default in `~/.codex/config.toml`.
- Use `--ephemeral -o "$(mktemp)"` and send the stream to `/dev/null`; require
  a hard reply budget. Pipe long logs, diffs, and test output through stdin.
- Use `--search -s read-only` for research/review; reserve
  `--dangerously-bypass-approvals-and-sandbox` for edits/tests. Use `-C <worktree>`.
- Run independent calls in parallel under `timeout`; use `resume --last` for
  long tasks and `review --uncommitted` for an independent second pass.

```bash
OUT=$(mktemp)
codex --search exec -m gpt-6-luna --ephemeral -s read-only -c 'model_reasoning_effort="max"' -o "$OUT" \
  'Latest release of X? One line.' >/dev/null 2>&1; cat "$OUT"
go test ./... 2>&1 | codex exec -m gpt-6-luna --ephemeral -s read-only -c 'model_reasoning_effort="max"' -o "$OUT" \
  'stdin is go test output; max 3 lines: failures only.' >/dev/null 2>&1; cat "$OUT"
codex exec -m gpt-6-luna -C "$WT" --dangerously-bypass-approvals-and-sandbox -c 'model_reasoning_effort="max"' -o "$OUT" \
  'Add X with a table test; iterate until gofmt is clean and `go test ./pkg/` passes. Max 5 lines.' >/dev/null 2>&1; cat "$OUT"
```

It's there for you. Use it.

Also use it at the end of each session to trim comments and simplify your MR messages.
