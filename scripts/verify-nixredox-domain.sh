#!/usr/bin/env bash
# Verify live DNS, TLS, COOP/COEP/CORP isolation headers, redirects, and mail hygiene
# for nixredox.com (canonical), nixredox.org (redirect), and legacy GitHub Pages.
set -euo pipefail

CANONICAL_HOST="nixredox.com"
REDIRECT_HOST="nixredox.org"
GITHUB_PAGES_BASE="https://brittonr.github.io/nix-redox"
RESOLVER="1.1.1.1"
USE_DOH=0
SKIP_GITHUB_PAGES=0
TIMEOUT=10

usage() {
  cat <<'EOF'
Usage: scripts/verify-nixredox-domain.sh [options]

Verify production cutover for https://nixredox.com/ and https://nixredox.org/.

Options:
  --doh                Query DNS over HTTPS (https://cloudflare-dns.com/dns-query)
  --resolver <ip>      DNS resolver passed to dig (default: 1.1.1.1)
  --skip-github-pages  Skip legacy brittonr.github.io/nix-redox/ redirect check
  --timeout <seconds>  Per-request curl timeout in seconds (default: 10)
  -h, --help           Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --doh)
    USE_DOH=1
    shift
    ;;
  --resolver)
    RESOLVER="${2:?--resolver requires an argument}"
    shift 2
    ;;
  --skip-github-pages)
    SKIP_GITHUB_PAGES=1
    shift
    ;;
  --timeout)
    TIMEOUT="${2:?--timeout requires an argument}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

for cmd in curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 2
  fi
done
if [ "$USE_DOH" -eq 0 ] && ! command -v dig >/dev/null 2>&1; then
  echo "dig not found; falling back to --doh" >&2
  USE_DOH=1
fi

PASS=0
FAIL=0
INFO=0

ok() {
  PASS=$((PASS + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '[FAIL] %s\n' "$1" >&2
}

info() {
  INFO=$((INFO + 1))
  printf '[INFO] %s\n' "$1"
}

fetch_headers() {
  local url="$1"
  curl -sS -D - -o /dev/null --max-time "$TIMEOUT" "$url" 2>/dev/null | tr -d '\r'
}

header_value() {
  local headers="$1"
  local name="$2"
  printf '%s\n' "$headers" | awk -v target="${name,,}" '
    BEGIN { FS = ":[[:space:]]*" }
    NR > 1 && tolower($1) == target {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print $0
    }
  ' | paste -sd ', ' -
}

http_status() {
  local headers="$1"
  printf '%s\n' "$headers" | awk 'NR == 1 { print $2 }'
}

check_isolation_headers() {
  local url="$1"
  local expect_cache="$2"
  local headers status coop coep corp nosniff cache

  if ! headers="$(fetch_headers "$url")"; then
    fail "$url: HTTP request failed"
    return
  fi
  status="$(http_status "$headers")"
  if [ "$status" != "200" ]; then
    fail "$url: expected HTTP 200, got ${status:-<none>}"
    return
  fi
  ok "$url: HTTP 200"

  coop="$(header_value "$headers" "cross-origin-opener-policy")"
  coep="$(header_value "$headers" "cross-origin-embedder-policy")"
  corp="$(header_value "$headers" "cross-origin-resource-policy")"
  nosniff="$(header_value "$headers" "x-content-type-options")"
  cache="$(header_value "$headers" "cache-control")"

  if [ "${coop,,}" = "same-origin" ]; then
    ok "$url: COOP=same-origin"
  else
    fail "$url: COOP expected same-origin, got '${coop:-<missing>}'"
  fi

  if [ "${coep,,}" = "require-corp" ]; then
    ok "$url: COEP=require-corp"
  else
    fail "$url: COEP expected require-corp, got '${coep:-<missing>}'"
  fi

  if [ "${corp,,}" = "same-origin" ]; then
    ok "$url: CORP=same-origin"
  else
    fail "$url: CORP expected same-origin, got '${corp:-<missing>}'"
  fi

  if [ "${nosniff,,}" = "nosniff" ]; then
    ok "$url: X-Content-Type-Options=nosniff"
  else
    fail "$url: X-Content-Type-Options expected nosniff, got '${nosniff:-<missing>}'"
  fi

  case "$expect_cache" in
  no-store)
    if [[ ${cache,,} == *no-store* ]] && [[ ${cache,,} != *immutable* ]]; then
      ok "$url: Cache-Control=${cache}"
    else
      fail "$url: Cache-Control expected no-store (not immutable), got '${cache:-<missing>}'"
    fi
    ;;
  immutable)
    if [[ ${cache,,} == *immutable* ]] && [[ ${cache,,} != *no-store* ]]; then
      ok "$url: Cache-Control=${cache}"
    else
      fail "$url: Cache-Control expected immutable (not no-store), got '${cache:-<missing>}'"
    fi
    ;;
  esac
}

check_redirect() {
  local source_url="$1"
  local expected_target="$2"
  local headers status loc next_headers next_status next_loc

  if ! headers="$(fetch_headers "$source_url")"; then
    fail "Redirect $source_url -> $expected_target: request failed"
    return
  fi
  status="$(http_status "$headers")"
  loc="$(header_value "$headers" "location")"

  if [ "$status" != "301" ] && [ "$status" != "308" ]; then
    fail "Redirect $source_url: expected 301 or 308, got ${status:-<none>} (Location: ${loc:-<none>})"
    return
  fi

  if [ "$loc" = "$expected_target" ]; then
    ok "Redirect $source_url -> $loc (HTTP $status)"
    return
  fi

  # Allow http://<redirect-host>/... -> https://<redirect-host>/... -> https://<canonical-host>/...
  if [[ $source_url == http://* ]] && [[ $loc == https://* ]]; then
    if next_headers="$(fetch_headers "$loc")"; then
      next_status="$(http_status "$next_headers")"
      next_loc="$(header_value "$next_headers" "location")"
      if { [ "$next_status" = "301" ] || [ "$next_status" = "308" ]; } && [ "$next_loc" = "$expected_target" ]; then
        ok "Redirect $source_url -> $loc ($status) -> $next_loc ($next_status)"
        return
      fi
    fi
  fi

  fail "Redirect $source_url: expected Location '$expected_target', got '${loc:-<none>}' (HTTP $status)"
}

check_github_pages_redirect() {
  local url="$1"
  local expected_target="$2"
  local headers status loc body

  if ! headers="$(fetch_headers "$url")"; then
    fail "GitHub Pages $url: request failed"
    return
  fi
  status="$(http_status "$headers")"
  loc="$(header_value "$headers" "location")"

  if { [ "$status" = "301" ] || [ "$status" = "308" ]; } && [ "$loc" = "$expected_target" ]; then
    ok "GitHub Pages $url -> $loc (HTTP $status)"
    return
  fi

  if [ "$status" = "200" ]; then
    body="$(curl -sS --max-time "$TIMEOUT" "$url" 2>/dev/null || true)"
    if [[ $body == *"url=${expected_target}"* ]] && [[ $body == *"<link rel=\"canonical\" href=\"${expected_target}\">"* ]]; then
      ok "GitHub Pages $url: static HTML canonical redirect -> $expected_target"
      return
    fi
  fi

  fail "GitHub Pages $url: expected redirect to $expected_target (got HTTP ${status:-<none>}, Location: ${loc:-<none>})"
}

dns_query() {
  local name="$1"
  local rtype="$2"
  if [ "$USE_DOH" -eq 1 ]; then
    curl -sS --max-time "$TIMEOUT" \
      -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=${name}&type=${rtype}" |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
status = data.get("Status")
if status != 0:
    print(f"__DNS_STATUS__={status}")
    sys.exit(0)
for ans in data.get("Answer", []):
    val = ans.get("data", "")
    if val:
        print(val)
'
  else
    local out status
    out="$(dig "@${RESOLVER}" +time=3 +tries=1 "$name" "$rtype" 2>/dev/null || true)"
    status="$(printf '%s\n' "$out" | awk -F'status: ' '/status:/{print $2}' | cut -d, -f1 | head -n1)"
    if [ "$status" != "NOERROR" ]; then
      echo "__DNS_STATUS__=${status:-TIMEOUT}"
      return
    fi
    dig "@${RESOLVER}" +time=3 +tries=1 +short "$name" "$rtype" 2>/dev/null || true
  fi
}

check_dns_hygiene() {
  local domain="$1"
  local ns mx txt dmarc caa ds

  ns="$(dns_query "$domain" NS)"
  if [[ $ns == __DNS_STATUS__* ]] || [ -z "$ns" ]; then
    fail "DNS $domain NS: no authoritative answer (${ns:-empty})"
  else
    ok "DNS $domain NS: $(printf '%s' "$ns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi

  mx="$(dns_query "$domain" MX)"
  if [[ $mx == __DNS_STATUS__* ]] || [ -z "$mx" ]; then
    fail "DNS $domain MX: expected null MX '0 .', got '${mx:-<missing>}'"
  else
    local non_null
    non_null="$(printf '%s\n' "$mx" | grep -vE '^[[:space:]]*0[[:space:]]+\.[[:space:]]*$' || true)"
    if [ -z "$non_null" ]; then
      ok "DNS $domain MX: null MX (0 .)"
    else
      fail "DNS $domain MX: expected only null MX '0 .', got: $(printf '%s' "$mx" | tr '\n' '; ')"
    fi
  fi

  txt="$(dns_query "$domain" TXT)"
  if printf '%s\n' "$txt" | grep -q 'v=spf1 -all'; then
    ok "DNS $domain SPF: v=spf1 -all"
  else
    fail "DNS $domain SPF: missing 'v=spf1 -all' (got: ${txt:-<none>})"
  fi

  dmarc="$(dns_query "_dmarc.${domain}" TXT)"
  if printf '%s\n' "$dmarc" | grep -q 'v=DMARC1' && printf '%s\n' "$dmarc" | grep -q 'p=reject'; then
    ok "DNS _dmarc.$domain: p=reject"
  else
    fail "DNS _dmarc.$domain: expected v=DMARC1 with p=reject (got: ${dmarc:-<none>})"
  fi

  caa="$(dns_query "$domain" CAA)"
  if [[ $caa != __DNS_STATUS__* ]] && printf '%s\n' "$caa" | grep -qiE 'issue(wild)?'; then
    ok "DNS $domain CAA: $(printf '%s' "$caa" | tr '\n' '; ' | sed 's/; $//')"
  else
    fail "DNS $domain CAA: missing CAA issue record (got: ${caa:-<none>})"
  fi

  ds="$(dns_query "$domain" DS)"
  if [[ $ds != __DNS_STATUS__* ]] && [ -n "$ds" ]; then
    info "DNS $domain DNSSEC: DS record published"
  else
    info "DNS $domain DNSSEC: no DS record published yet (optional)"
  fi
}

echo "=== 1. Canonical HTTPS, COOP/COEP/CORP, and Cache-Control ==="
check_isolation_headers "https://${CANONICAL_HOST}/" "no-store"
check_isolation_headers "https://${CANONICAL_HOST}/live/" "no-store"
check_isolation_headers "https://${CANONICAL_HOST}/channel.json" "no-store"

landing_html="$(curl -sS --max-time "$TIMEOUT" "https://${CANONICAL_HOST}/" 2>/dev/null || true)"
if [[ $landing_html == *"<link rel=\"canonical\" href=\"https://${CANONICAL_HOST}/\">"* ]]; then
  ok "https://${CANONICAL_HOST}/: canonical link tag matches"
else
  fail "https://${CANONICAL_HOST}/: missing <link rel=\"canonical\" href=\"https://${CANONICAL_HOST}/\">"
fi

channel_json="$(curl -sS --max-time "$TIMEOUT" "https://${CANONICAL_HOST}/channel.json" 2>/dev/null || true)"
revision=""
if [ -n "$channel_json" ]; then
  revision="$(
    printf '%s' "$channel_json" | python3 -c '
import json, re, sys
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rev = p.get("revision", "")
if p.get("schemaVersion") == 1 and re.fullmatch(r"[a-f0-9]{64}", rev):
    print(rev)
else:
    sys.exit(1)
' 2>/dev/null || true
  )"
fi

if [ -n "$revision" ]; then
  ok "https://${CANONICAL_HOST}/channel.json: valid revision ${revision:0:12}..."
  check_isolation_headers "https://${CANONICAL_HOST}/revisions/${revision}/manifest.json" "immutable"
  check_isolation_headers "https://${CANONICAL_HOST}/revisions/${revision}/live/" "immutable"
  check_isolation_headers "https://${CANONICAL_HOST}/revisions/${revision}/coi-serviceworker.js" "no-store"
else
  fail "https://${CANONICAL_HOST}/channel.json: unavailable or malformed"
fi

echo ""
echo "=== 2. Canonical Host & Scheme Redirects ==="
check_redirect "http://${CANONICAL_HOST}/" "https://${CANONICAL_HOST}/"
check_redirect "http://${CANONICAL_HOST}/live/" "https://${CANONICAL_HOST}/live/"
check_redirect "https://www.${CANONICAL_HOST}/" "https://${CANONICAL_HOST}/"
check_redirect "https://www.${CANONICAL_HOST}/live/" "https://${CANONICAL_HOST}/live/"
check_redirect "https://${REDIRECT_HOST}/" "https://${CANONICAL_HOST}/"
check_redirect "https://${REDIRECT_HOST}/live/?probe=1" "https://${CANONICAL_HOST}/live/?probe=1"
check_redirect "http://${REDIRECT_HOST}/live/" "https://${CANONICAL_HOST}/live/"
check_redirect "https://www.${REDIRECT_HOST}/" "https://${CANONICAL_HOST}/"
check_redirect "https://www.${REDIRECT_HOST}/live/" "https://${CANONICAL_HOST}/live/"

echo ""
echo "=== 3. Legacy GitHub Pages Origin Redirect ==="
if [ "$SKIP_GITHUB_PAGES" -eq 1 ]; then
  info "Skipping GitHub Pages redirect check (--skip-github-pages)"
else
  check_github_pages_redirect "${GITHUB_PAGES_BASE}/" "https://${CANONICAL_HOST}/"
  check_github_pages_redirect "${GITHUB_PAGES_BASE}/live/" "https://${CANONICAL_HOST}/live/"
fi

echo ""
echo "=== 4. DNS & Mail Hygiene ==="
check_dns_hygiene "$CANONICAL_HOST"
check_dns_hygiene "$REDIRECT_HOST"

echo ""
echo "=== Summary ==="
printf 'Passed: %d | Failed: %d | Info: %d\n' "$PASS" "$FAIL" "$INFO"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
