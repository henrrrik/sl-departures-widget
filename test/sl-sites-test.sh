#!/usr/bin/env bash
# Tests for bin/sl-sites, run with: bash test/sl-sites-test.sh
#
# A fake curl on PATH stands in for SL, so nothing touches the network. It
# writes a small stop list, or answers 429 when FAKE_CURL_STATUS=429.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp"

cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
out="" status=${FAKE_CURL_STATUS:-200} writeout=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -w) writeout=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $writeout ]] && printf 'SLHTTP %s %s\n' "$status" "${FAKE_RETRY_AFTER:-}" >&2
if [[ $status != 200 ]]; then
  printf 'curl: (22) The requested URL returned error: %s\n' "$status" >&2
  exit 22
fi
printf '[{"id":9192,"name":"Slussen"},{"id":1,"name":"Ørestad"},{"id":2,"name":"Södermalm"}]' > "$out"
CURL
chmod +x "$work/bin/curl"

export PATH="$work/bin:$PATH" TMPDIR="$work/tmp" XDG_CACHE_HOME="$work/cache"
sl_sites() { bash "$root/bin/sl-sites" "$@"; }

failures=0
check() {
  if [[ $2 == "$3" ]]; then printf 'ok - %s\n' "$1"
  else printf 'not ok - %s\n  expected: %q\n  got:      %q\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}

# A cold download succeeds and says so. It used to exit 1: the RETURN trap
# that cleaned up the temp file fired again after ensure_cache returned.
out=$(sl_sites --ensure-cache 2>&1) && code=0 || code=$?
check "a cold --ensure-cache exits 0" "$code" 0
check "a cold --ensure-cache reports the download" "$out" fetched

out=$(sl_sites --ensure-cache 2>&1) && code=0 || code=$?
check "a fresh cache is left alone" "$code:$out" "0:"

# The widget's --status line, and a 429 surfacing as curl's exit 22.
rm -rf -- "$work/cache"
out=$(FAKE_CURL_STATUS=429 FAKE_RETRY_AFTER=300 sl_sites --ensure-cache --status 2>&1) && code=0 || code=$?
check "a 429 exits 22" "$code" 22
check "--status writes the status line" "$(grep '^SLHTTP' <<<"$out")" "SLHTTP 429 300"

out=$(sl_sites --ensure-cache 2>&1 >/dev/null) || true
check "without --status there is no status line" "$(grep -c '^SLHTTP' <<<"$out" || true)" 0

# Searches fold like the widget's picker.
check "ø folds to o" "$(sl_sites ørest | awk '{print $1}')" 1
check "a decomposed letter folds" "$(sl_sites "$(printf 'So\xcc\x88der')" | awk '{print $1}')" 2
# A needle that folds to nothing used to match every stop.
out=$(sl_sites "$(printf '\xcc\x88')" 2>&1) && code=0 || code=$?
check "a search that folds to nothing is refused" "$code:$out" "1:search for at least one letter"

# Failures leave no temp files behind.
sl_sites zzz >/dev/null 2>&1 || true
rm -rf -- "$work/cache"
FAKE_CURL_STATUS=503 sl_sites --ensure-cache >/dev/null 2>&1 || true
check "no temp files leak" "$(find "$work/tmp" "$work/cache" -type f -name '*' ! -name 'sl-sites.json' 2>/dev/null | wc -l)" 0

(( failures == 0 )) || { printf '%d failed\n' "$failures"; exit 1; }
