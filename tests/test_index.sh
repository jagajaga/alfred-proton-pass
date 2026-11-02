#!/bin/bash
# Tests for scripts/index.sh against a fake pass-cli (tests/bin/pass-cli).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INDEX="$HERE/../scripts/index.sh"
export PATH="$HERE/bin:$PATH"
export PP_RETRY_DELAY=0.1   # keep the `info` retry loop fast under test

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

setup() {
  T="$(mktemp -d)"
  export FAKE_DIR="$T/fake" alfred_workflow_cache="$T/cache"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/calls.log"
}
teardown() { rm -rf "$T"; }

cache_has_items() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("items") else 1)' "$alfred_workflow_cache/index.json"; }
cache_error()     { python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("errors") or [""])[0])' "$alfred_workflow_cache/index.json"; }
count_calls()     { grep -c "^$1" "$FAKE_DIR/calls.log" || true; }

# 1. A single transient `pass-cli info` failure must not be cached as "not logged in".
setup
echo 1 >"$FAKE_DIR/info_fail_count"
"$INDEX" --force
if cache_has_items; then pass "transient info failure is retried, items cached"; else fail "transient info failure cached as: $(cache_error)"; fi
teardown

# 2. A persistent failure still yields "not logged in", after a bounded number of tries.
setup
echo 99 >"$FAKE_DIR/info_fail_count"
"$INDEX" --force
err="$(cache_error)"; n="$(count_calls info)"
if [[ "$err" == *"not logged in"* ]]; then pass "persistent failure reports not logged in"; else fail "expected not-logged-in error, got: $err"; fi
if (( n >= 2 && n <= 5 )); then pass "info retried a bounded number of times ($n)"; else fail "info called $n times"; fi
teardown

# 3. Concurrent indexers must not both run pass-cli: the second waits and reuses the first's cache.
setup
echo 1 >"$FAKE_DIR/sleep"
"$INDEX" --force & p1=$!
sleep 0.2
"$INDEX" --force & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
n="$(count_calls 'vault list')"
if (( n == 1 )); then pass "concurrent runs serialised (vault list called once)"; else fail "vault list called $n times under concurrency"; fi
if (( r1 == 0 && r2 == 0 )); then pass "both concurrent runs exit 0"; else fail "exit codes $r1 $r2"; fi
if cache_has_items; then pass "cache populated after concurrent runs"; else fail "cache empty after concurrent runs"; fi
teardown

# 4. A lock left behind by a killed run is broken once stale, so indexing still happens.
setup
mkdir -p "$alfred_workflow_cache/index.lockdir"
python3 -c 'import os,sys,time; t=time.time()-600; os.utime(sys.argv[1],(t,t))' "$alfred_workflow_cache/index.lockdir"
"$INDEX" --force
if cache_has_items; then pass "stale lock is broken"; else fail "stale lock blocked indexing"; fi
if [[ ! -d "$alfred_workflow_cache/index.lockdir" ]]; then pass "lock released on exit"; else fail "lock dir left behind"; fi
teardown

echo
if (( fails == 0 )); then echo "index.sh: all tests passed"; else echo "index.sh: $fails test(s) FAILED"; exit 1; fi
