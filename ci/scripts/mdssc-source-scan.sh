#!/usr/bin/env bash
# Runs an MDSSC source code scan via POST /api/v1/scans.
# Falls back to a mock result when secrets are not configured.
set -euo pipefail

MDSSC_INSTANCE="${MDSSC_INSTANCE:-}"
MDSSC_API_KEY="${MDSSC_API_KEY:-}"
VULNERABILITY_THRESHOLD="${VULNERABILITY_THRESHOLD:-critical}"
FAIL_ON_SECRET="${FAIL_ON_SECRET:-true}"
FAIL_ON_MALWARE="${FAIL_ON_MALWARE:-true}"

mkdir -p scan-results

# ── Mock path (no secrets configured) ────────────────────────────────────────
if [[ -z "$MDSSC_INSTANCE" || -z "$MDSSC_API_KEY" ]]; then
  echo "::warning::MDSSC_INSTANCE / MDSSC_API_KEY not set — using mock scan result (pipeline will pass)"
  cat > scan-results/source-scan.json <<'EOF'
{
  "id": "mock-src-001",
  "status": "COMPLETED",
  "mock": true,
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0 },
  "secrets": 0,
  "malware": 0
}
EOF
  echo "passed=true"  >> "$GITHUB_OUTPUT"
  echo "scan-id=mock-src-001" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── Health check ──────────────────────────────────────────────────────────────
echo "::group::MDSSC health check"
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "x-api-key: ${MDSSC_API_KEY}" \
  "${MDSSC_INSTANCE}/api/v1/health") || true

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "::error::MDSSC unreachable (HTTP ${HTTP_STATUS})"
  exit 1
fi
echo "MDSSC instance healthy"
echo "::endgroup::"

# ── Start scan ────────────────────────────────────────────────────────────────
echo "::group::Starting source code scan"
SCAN_PAYLOAD=$(printf '{"repository":"%s","branch":"%s","commitSha":"%s"}' \
  "${GITHUB_REPOSITORY:-local}" \
  "${GITHUB_REF_NAME:-main}" \
  "${GITHUB_SHA:-unknown}")

SCAN_RESPONSE=$(curl -sf \
  -X POST \
  -H "x-api-key: ${MDSSC_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$SCAN_PAYLOAD" \
  "${MDSSC_INSTANCE}/api/v1/scans")

SCAN_ID=$(echo "$SCAN_RESPONSE" | jq -r '.id')
echo "Scan ID: $SCAN_ID"
echo "scan-id=$SCAN_ID" >> "$GITHUB_OUTPUT"
echo "::endgroup::"

# ── Poll for completion ───────────────────────────────────────────────────────
echo "::group::Polling scan status"
MAX_RETRIES=60
RETRY_DELAY=10

for i in $(seq 1 $MAX_RETRIES); do
  OVERVIEW=$(curl -sf \
    -H "x-api-key: ${MDSSC_API_KEY}" \
    "${MDSSC_INSTANCE}/api/v1/scans/${SCAN_ID}/overview")
  STATUS=$(echo "$OVERVIEW" | jq -r '.status')
  echo "  [${i}/${MAX_RETRIES}] status: $STATUS"
  if [[ "$STATUS" != "IN_PROGRESS" ]]; then break; fi
  sleep $RETRY_DELAY
done
echo "::endgroup::"

# ── Fetch full result ─────────────────────────────────────────────────────────
echo "::group::Fetching full scan results"
RESULT=$(curl -sf \
  -H "x-api-key: ${MDSSC_API_KEY}" \
  "${MDSSC_INSTANCE}/api/v1/scans/${SCAN_ID}")
echo "$RESULT" | jq '.' > scan-results/source-scan.json
echo "::endgroup::"

# ── Apply thresholds ──────────────────────────────────────────────────────────
CRITICAL=$(echo "$RESULT" | jq -r '.summary.critical // 0')
HIGH=$(echo "$RESULT"     | jq -r '.summary.high     // 0')
MEDIUM=$(echo "$RESULT"   | jq -r '.summary.medium   // 0')
LOW=$(echo "$RESULT"      | jq -r '.summary.low      // 0')
UNKNOWN=$(echo "$RESULT"  | jq -r '.summary.unknown  // 0')
SECRETS=$(echo "$RESULT"  | jq -r '.secrets          // 0')
MALWARE=$(echo "$RESULT"  | jq -r '.malware          // 0')

echo "Findings — critical:$CRITICAL high:$HIGH medium:$MEDIUM low:$LOW unknown:$UNKNOWN secrets:$SECRETS malware:$MALWARE"

FAILED=false
case "$VULNERABILITY_THRESHOLD" in
  none)    ;;
  unknown) [[ $UNKNOWN -gt 0 || $LOW -gt 0 || $MEDIUM -gt 0 || $HIGH -gt 0 || $CRITICAL -gt 0 ]] && FAILED=true ;;
  low)     [[ $LOW     -gt 0 || $MEDIUM -gt 0 || $HIGH -gt 0 || $CRITICAL -gt 0 ]] && FAILED=true ;;
  medium)  [[ $MEDIUM  -gt 0 || $HIGH -gt 0 || $CRITICAL -gt 0 ]] && FAILED=true ;;
  high)    [[ $HIGH    -gt 0 || $CRITICAL -gt 0 ]] && FAILED=true ;;
  critical)[[ $CRITICAL -gt 0 ]] && FAILED=true ;;
esac
[[ "$FAIL_ON_SECRET" == "true" && $SECRETS -gt 0 ]] && FAILED=true
[[ "$FAIL_ON_MALWARE" == "true" && $MALWARE -gt 0 ]] && FAILED=true

if [[ "$FAILED" == "true" ]]; then
  echo "::error::Source code scan FAILED — findings exceed configured thresholds"
  echo "passed=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

echo "passed=true" >> "$GITHUB_OUTPUT"
echo "Source code scan PASSED"
