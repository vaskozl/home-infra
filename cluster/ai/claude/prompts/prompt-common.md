## Environment

You run as `nonroot` on a Wolfi-based container image inside the `home-infra` Kubernetes cluster (namespace: `ai`). You have read-only access to the cluster via your pod's service account — use `kubectl` to inspect workloads, pods, events, and resources across all namespaces.

Your home directory is `/home/nonroot/` — clone repos here (e.g., `/home/nonroot/<repo>`). **Do not** use `/root/` — it is not accessible to uid 568.

If something is wrong or missing, fix it temporarily then log an issue with `glab issue create -R <repo>` so it gets permanently fixed:

| Problem | Temp fix | Issue repo |
|---|---|---|
| Missing tool / binary | `brew install <pkg>` | `doudous/claude-img` |
| Wolfi apk package needed | `brew install <pkg>` | `doudous/apkontainers` |
| Claude config or settings issue | — | `doudous/claude-img` |
| Prompt issues (unclear/missing instructions in this file) | — | `doudous/home-infra` |

## Tech preferences

- **Backend code**: Write efficient, lean server side templated pages HTML sites. Prefer full-page navigation — it's simpler and correct. For cases that genuinely need partial page swaps, use [fixi.js](https://github.com/bigskysoftware/fixi) (a light htmx alternative that can be vendored) rather than heavier JS frameworks.
- **One-liners**: Reach for `perl` over `python`/`awk`/`sed` — it's always available and usually shorter:
  ```bash
  perl -MJSON::XS -lane 'print decode_json($_)->{name}' file.json
  perl -lane 'print $F[2]' file.txt   # awk '{print $3}'
  perl -pe 's/foo/bar/g'              # sed 's/foo/bar/g'
  ```
- **HTTP + JSON**: Mojolicious is installed. Use `ojo` for one-liners and `Mojo::UserAgent` / `Mojo::JSON` in scripts — much shorter than `curl | jq` or `LWP::UserAgent` + `JSON::PP`:
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

- **`glab mr list --state`**: Not supported by glab. Use `glab mr list` (defaults to open MRs) or query the API: `glab api "projects/$(printf '%s' 'group/repo' | jq -Rr @uri)/merge_requests?state=opened"`.
- **`glab issue close -c`**: The `-c` flag does not exist. To close an issue with a comment, use two separate commands: `glab issue close <id> -R <repo>` then `glab issue note <id> -R <repo> -m "..."`.
- **`python3`**: Not installed in the container. Use `jq` or `perl` for all JSON/text processing.

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
| Add MR comment | `glab mr note <id> -R <repo> -m "comment"` |
| Resolve MR thread | `glab mr note <id> -R <repo> --resolve <discussion_id>` |
| View CI status | `glab ci view <mr_iid> -R <repo>` |
| API query | `glab api "projects/$(printf '%s' 'group/repo' \| jq -Rr @uri)/merge_requests?state=opened"` |

> **glab JSON label format (important)**
> - All `glab --output json` output (issue view/list, mr view/list) returns labels as **plain strings**: `["label1", "label2"]`.
> - Always iterate with `.labels[]` — never `.labels[].name`, which will fail with `Cannot index string with string "name"`.
> - Always add `2>/dev/null` after jq in parallel batches to prevent exit-code cascades from aborting sibling tool calls.

### Uploading image evidence

Use the chrome-devtools MCP tools to take a screenshot, save it to `/tmp/screenshots/evidence.png` (a volume shared between the `claude` and `chrome-devtools-mcp` containers), upload it to GitLab, and embed the returned markdown in your MR or issue comment:

```bash
# 1. Upload to GitLab (glab api doesn't support multipart, use curl)
UPLOAD=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --form "file=@/tmp/screenshots/evidence.png" \
  "${GITLAB_HOST}/api/v4/projects/${repo/\//%2F}/uploads")
IMG_MD=$(echo "$UPLOAD" | jq -r '.markdown')
# 2. Use $IMG_MD in a comment
glab mr note <id> -R <repo> -m "## Evidence
${IMG_MD}"
```
