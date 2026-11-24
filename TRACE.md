# Trace format

Truthy uses small append-only records so an investigation can be inspected with ordinary command-line tools.

## `trace.tsv`

Columns:

```text
utc\tkind\tkey\tvalue
```

`kind` examples: `new`, `search`, `fetch`, `links`, `model`, `claim`, `decision`, `issue`.

`key` is a stable local identifier when one exists: a URL, SHA-256 digest, model-run directory, claim id, or issue URL.

`value` is a single-line note.  Tabs and newlines are replaced with spaces before append.

The UTC timestamp describes when the step happened.  It is not part of a content identity.

## `edges.tsv`

```text
from_kind\tfrom_key\trelation\tto_kind\tto_key\tnote
```

This is the investigation graph.  It records branch points directly: search → URL, URL → frozen artifact, artifact → extracted URL, evidence → claim, prompt → model run, and any manual branch added with `truthy-edge`.  A linear trace is useful for chronology; `edges.tsv` preserves why one path teed off into another.

## `searches.tsv`

```text
utc\tprovider\tquery\tresult_url
```

Record searches even when the result is ultimately rejected.  Multiple result URLs may be appended for the same query.

## `claims.tsv`

Recommended columns:

```text
claim_id\tstatus\tclaim\tevidence\tnote
```

Suggested status vocabulary is descriptive rather than magical: `unreviewed`, `supported`, `contradicted`, `mixed`, `not-established`, `out-of-scope`.

`evidence` should point to a frozen artifact hash plus a location within it when practical.

## Artifact identity

Fetched bodies live at:

```text
artifacts/sha256/<sha256>/body
```

Each fetch publishes its own private directory at `artifacts/sha256/<sha256>/fetches/observation-<opaque-id>`. A repeat at the same URL can add an observation to the same body without replacing either set of headers. `headers.txt` preserves the responses, including redirects. `curl-result.txt` retains raw HTTP status, effective URL, and content type on separate lines. `url.txt` records the requested URL and `stderr.txt` retains curl's diagnostics. `fetch.tsv` keeps its five columns for UTC, curl exit status, HTTP status, effective URL and content type. `body-state.txt` distinguishes a missing response body from a present empty body. The existing empty bytes convention for a missing body preserves the command's digest and artifact directory output.

Fetch and model writers share one publication lock. Bodies are added by a no-replacement link, and a reused body must match its directory digest. The fetch trace identifies the observation by its relative path. The graph connects the requested URL to both its observation and artifact, with a separate observation-to-artifact edge.

## Model run identity

Each run records:

```text
model-runs/run-<opaque-id>/
  model-id.txt
  model-revision.txt
  command.txt
  argv.nul
  prompt.txt
  stdout.txt
  stderr.txt
  hashes.tsv
  exit-status.txt
  captured-utc.txt
```

The runner requires nonempty, single-line model and revision labels. Each worker invocation gets an independent identity even when multiple invocations share the prompt, worker and second. `argv.nul` preserves the command and arguments byte for byte. `captured-utc.txt` records completion time.

`truthy-model` stages its files privately on the investigation filesystem. It uses `flock` to serialize model capture publication and index writes. The completed record appears as one directory, and new model trace and edge entries refer to that directory by its relative path. A worker's nonzero exit and diagnostics are retained. An interrupted final index write can leave a completed record that requires reconciliation. Older timestamp-prefixed directories and their records are left in place.
