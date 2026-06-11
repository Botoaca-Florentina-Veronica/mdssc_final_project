#!/usr/bin/env bash
# Uploads an artifact and runs an MDSSC direct scan via POST /api/v1/scans/direct.
# Falls back to a mock result when secrets are not configured.
set -euo pipefail

MDSSC_INSTANCE="${MDSSC_INSTANCE:-}"
MDSSC_API_KEY="${MDSSC_API_KEY:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-plugin/mdssc-plugin.hpi}"
VULNERABILITY_THRESHOLD="${VULNERABILITY_THRESHOLD:-critical}"
FAIL_ON_SECRET="${FAIL_ON_SECRET:-true}"
FAIL_ON_MALWARE="${FAIL_ON_MALWARE:-true}"

mkdir -p scan-results

# ── Validate artifact exists ──────────────────────────────────────────────────
if [[ ! -f "$ARTIFACT_PATH" ]]; then
  echo "::error::Artifact not found: $ARTIFACT_PATH"
  exit 1
fi
echo "Artifact: $ARTIFACT_PATH ($(du -sh "$ARTIFACT_PATH" | cut -f1))"

# ── Mock path (no secrets configured) ────────────────────────────────────────
if [[ -z "$MDSSC_INSTANCE" || -z "$MDSSC_API_KEY" ]]; then
  echo "::warning::MDSSC_INSTANCE / MDSSC_API_KEY not set — using mock scan result (pipeline will pass)"
  cat > scan-results/artifact-scan.json <<'EOF'
{
  "id": "mock-art-001",
  "status": "COMPLETED",
  "mock": true,
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0 },
  "secrets": 0,
  "malware": 0
}
EOF
  echo "passed=true"  >> "$GITHUB_OUTPUT"
  echo "scan-id=mock-art-001" >> "$GITHUB_OUTPUT"
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

# ── Upload and start scan ─────────────────────────────────────────────────────
echo "::group::Uploading artifact and starting scan"
SCAN_RESPONSE=$(curl -sf \
  -X POST \
  -H "x-api-key: ${MDSSC_API_KEY}" \
  -F "file=@${ARTIFACT_PATH}" \
  "${MDSSC_INSTANCE}/api/v1/scans/direct")

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
echo "$RESULT" | jq '.' > scan-results/artifact-scan.json
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
  echo "::error::Artifact scan FAILED — findings exceed configured thresholds"
  echo "passed=false" >> "$GITHUB_OUTPUT"
  exit 1
fi

echo "passed=true" >> "$GITHUB_OUTPUT"
echo "Artifact scan PASSED"
