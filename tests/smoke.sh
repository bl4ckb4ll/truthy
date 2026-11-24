#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/truthy-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

sh "$root/bin/truthy-new" "$work/run" 'fixture question'
sh "$root/bin/truthy-search-log" "$work/run" fixture 'alpha query' 'https://example.org/alpha'

expected="$work/expected"
actual="$work/actual"
printf '%s\n' \
  'https://example.org/alpha' \
  'https://example.org/beta' > "$expected"
python3 "$root/bin/truthy-links.py" "$root/tests/fixtures/page.html" 'https://example.org/start' > "$actual"
cmp "$expected" "$actual"

fixture="$root/tests/fixtures/page.html"
link_run="$work/run"
checksum=$(sha256sum < "$fixture")
digest=${checksum%% *}
bucket="$link_run/artifacts/sha256/$digest"
mkdir "$bucket"
cp "$fixture" "$bucket/body"

attach_links() {
    python3 "$root/bin/truthy-links.py" "$1" 'https://example.org/start' \
        --run "$link_run" --artifact-hash "$digest"
}

attach_links "$fixture" > "$actual"
cmp "$expected" "$actual"
for link in 'https://example.org/alpha' 'https://example.org/beta'; do
    edge=$(printf 'artifact\t%s\tlinks-to\turl\t%s\t' "$digest" "$link")
    grep -Fx "$edge" "$link_run/edges.tsv" >/dev/null
done
trace_entry=$(printf '\tlinks\t%s\tcount=2 base=https://example.org/start' "$digest")
grep -F "$trace_entry" "$link_run/trace.tsv" >/dev/null

cp "$link_run/edges.tsv" "$work/link-edges.before"
cp "$link_run/trace.tsv" "$work/link-trace.before"

require_link_rejection() {
    if attach_links "$1" > "$actual" 2> "$work/link-error"; then
        echo "truthy smoke: unexpectedly accepted $2" >&2
        exit 1
    fi
    test ! -s "$actual"
    grep -F "$2" "$work/link-error" >/dev/null
    cmp "$work/link-edges.before" "$link_run/edges.tsv"
    cmp "$work/link-trace.before" "$link_run/trace.tsv"
}

printf '<p>Other fixture bytes</p>\n' > "$work/other.html"
require_link_rejection "$work/other.html" 'input BODY does not match --artifact-hash'
cp "$work/other.html" "$bucket/body"
require_link_rejection "$fixture" 'stored artifact body does not match SHA-256'
rm "$bucket/body"
require_link_rejection "$fixture" 'stored artifact body is missing or invalid'

printf 'prompt body\n' | sh "$root/bin/truthy-model" "$work/run" fixture-model fixture-rev -- cat > "$work/model.out"
printf 'prompt body\n' > "$work/model.expected"
cmp "$work/model.expected" "$work/model.out"

grep -q 'fixture question' "$work/run/question.txt"
grep -q 'alpha query' "$work/run/searches.tsv"
grep -q 'fixture-model' "$work/run/trace.tsv"

# Both worker calls observe the same clock value, even when the test starts
# near a second boundary. The scripts still run in separate processes.
model_with_fixed_clock() {
    sh -c '
        date() {
            case "$2" in
                +%Y%m%dT%H%M%SZ) printf "20261124T123456Z\n" ;;
                +%Y-%m-%dT%H:%M:%SZ) printf "2026-11-24T12:34:56Z\n" ;;
                *) return 1 ;;
            esac
        }
        script=$1
        shift
        . "$script"
    ' model-fixture "$root/bin/truthy-model" "$@"
}

run="$work/parallel"
umask 022
sh "$root/bin/truthy-new" "$run" 'capture fixture'
worker='printf "%s\n" "$1"; cat; printf "%s\n" "$2" >&2; exit "$3"'
multiline=$(printf 'first line\nsecond line\twith tab')
model_with_fixed_clock "$run" same-model same-rev -- sh -c "$worker" worker success "$multiline" 0 \
    < "$work/model.expected" > "$work/success.out" &
success_pid=$!
model_with_fixed_clock "$run" same-model same-rev -- sh -c "$worker" worker failure 'failed on purpose' 7 \
    < "$work/model.expected" > "$work/failure.out" &
failure_pid=$!

wait "$success_pid"
worker_status=0
wait "$failure_pid" || worker_status=$?
test "$worker_status" -eq 7
printf 'success\nprompt body\n' > "$work/success.expected"
printf 'failure\nprompt body\n' > "$work/failure.expected"
cmp "$work/success.expected" "$work/success.out"
cmp "$work/failure.expected" "$work/failure.out"

set -- "$run"/model-runs/run-*
test "$#" -eq 2
for capture in "$@"; do
    cmp "$work/model.expected" "$capture/prompt.txt"
    test "$(cat "$capture/model-id.txt")" = same-model
    test "$(cat "$capture/model-revision.txt")" = same-rev
    test "$(cat "$capture/captured-utc.txt")" = '2026-11-24T12:34:56Z'
    case $(cat "$capture/exit-status.txt") in
        0)
            cmp "$work/success.expected" "$capture/stdout.txt"
            printf '%s\n' "$multiline" > "$work/stderr.expected"
            printf '%s\0' sh -c "$worker" worker success "$multiline" 0 > "$work/argv.expected"
            ;;
        7)
            cmp "$work/failure.expected" "$capture/stdout.txt"
            printf 'failed on purpose\n' > "$work/stderr.expected"
            printf '%s\0' sh -c "$worker" worker failure 'failed on purpose' 7 > "$work/argv.expected"
            ;;
        *) exit 1 ;;
    esac
    cmp "$work/stderr.expected" "$capture/stderr.txt"
    cmp "$work/argv.expected" "$capture/argv.nul"
    for stream in prompt stdout stderr; do
        digest=$(sha256sum < "$capture/$stream.txt")
        expected_hash=$(printf '%s\t%s' "$stream" "${digest%% *}")
        grep -Fx "$expected_hash" "$capture/hashes.tsv" >/dev/null
    done
    key="model-runs/${capture##*/}"
    trace_prefix=$(printf '2026-11-24T12:34:56Z\tmodel\t%s\t' "$key")
    edge_key=$(printf '\tanalyzed-by\tmodel-run\t%s\t' "$key")
    test "$(grep -Fc "$trace_prefix" "$run/trace.tsv")" -eq 1
    test "$(grep -Fc "$edge_key" "$run/edges.tsv")" -eq 1
done
test "$(find "$run" -perm /077 -print)" = ''
test "$(find "$run/model-runs" -name '.pending.*' -print)" = ''

cp "$run/trace.tsv" "$work/trace.before"
cp "$run/edges.tsv" "$work/edges.before"
label_status=0
model_with_fixed_clock "$run" same-model "$multiline" -- cat < "$work/model.expected" \
    > "$work/bad.out" 2> "$work/bad.err" || label_status=$?
test "$label_status" -eq 2
cmp "$work/trace.before" "$run/trace.tsv"
cmp "$work/edges.before" "$run/edges.tsv"

echo 'truthy smoke: pass'
