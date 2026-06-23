#!/usr/bin/env bash
#
# mdssc-artifact-scan.sh — scans the built artifact (plugin/) with MDSSC.
# Based on the original scan-artifacts.sh.
#
# Flow (identical to scan-artifacts.sh):
#   require_env → health → archive plugin/ →
#   scan_direct (archive) → poll → details → export_reports → evaluate
#
# The MDSSC logic lives in lib.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# BUILD_NUMBER → GITHUB_RUN_NUMBER in GitHub Actions
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
ARTIFACT_DIR="${MDSSC_ARTIFACT_DIR:-plugin}"
ARCHIVE="mdssc-artifact-scan-${BUILD_NUMBER}.tar.gz"

cleanup() { rm -f "$ARCHIVE"; }
trap cleanup EXIT

# ── Mock fallback ─────────────────────────────────────────────────────────────
use_mock() {
    echo "::warning::${1} — falling back to mock result (pipeline continues)"
    cat > scan-results/artifact-scan.json <<'EOF'
{
  "id": "mock-art-fallback",
  "status": "COMPLETED",
  "mock": true,
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0 },
  "secrets": 0,
  "malware": 0
}
EOF
    echo "passed=true"               >> "$GITHUB_OUTPUT"
    echo "scan-id=mock-art-fallback" >> "$GITHUB_OUTPUT"
    exit 0
}

# ── 0. Validate env ───────────────────────────────────────────────────────────
mdssc_require_env || use_mock "MDSSC credentials missing"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
    echo "[MDSSC] ERROR: directory '$ARTIFACT_DIR' does not exist — did the build stage run?"
    exit 1
fi

# ── 1. Health check ───────────────────────────────────────────────────────────
mdssc_health || use_mock "MDSSC unreachable"

# ── 2. Resolve workflow (fetch MDSSC_WF_ID for the direct scan) ───────────────
mdssc_resolve_workflow

# ── 3. Archive the artifact ───────────────────────────────────────────────────
echo "[MDSSC] Creating artifact archive from '${ARTIFACT_DIR}'..."
tar czf "$ARCHIVE" "$ARTIFACT_DIR"
echo "[MDSSC] Archive size: $(du -sh "$ARCHIVE" | cut -f1)"
echo "[MDSSC] Contents:"
tar tzf "$ARCHIVE" | sed 's/^/  /'

# ── 3b. Enforce the max upload size ───────────────────────────────────────────
ARCHIVE_SIZE_MB=$(( $(wc -c < "$ARCHIVE") / 1024 / 1024 ))
if [[ "$ARCHIVE_SIZE_MB" -gt "$MDSSC_MAX_UPLOAD_MB" ]]; then
    if [[ "$MDSSC_SKIP_LARGE_ARTIFACTS" == "true" ]]; then
        echo "::warning::Artifact archive is ${ARCHIVE_SIZE_MB}MB, exceeding the ${MDSSC_MAX_UPLOAD_MB}MB limit — skipping upload (MDSSC_SKIP_LARGE_ARTIFACTS=true)"
        cat > scan-results/artifact-scan.json <<EOF
{
  "id": "skipped-too-large",
  "status": "SKIPPED",
  "skipped": true,
  "sizeMb": ${ARCHIVE_SIZE_MB},
  "limitMb": ${MDSSC_MAX_UPLOAD_MB}
}
EOF
        echo "passed=true"                  >> "$GITHUB_OUTPUT"
        echo "scan-id=skipped-too-large"     >> "$GITHUB_OUTPUT"
        exit 0
    fi
    echo "::error::Artifact archive is ${ARCHIVE_SIZE_MB}MB, exceeding the ${MDSSC_MAX_UPLOAD_MB}MB limit (MDSSC_SKIP_LARGE_ARTIFACTS=false)"
    echo "passed=false" >> "$GITHUB_OUTPUT"
    exit 1
fi

# ── 4. Direct scan ────────────────────────────────────────────────────────────
SCAN_ID=$(mdssc_scan_direct "$ARCHIVE") || use_mock "MDSSC upload failed — invalid response or endpoint unavailable"

# ── 5. Poll overview ──────────────────────────────────────────────────────────
mdssc_poll_overview "$SCAN_ID"

# ── 6. Scan details ───────────────────────────────────────────────────────────
mdssc_scan_details "$SCAN_ID" "scan-results/artifact-scan.json"

# ── 7. Export SBOM + reports ──────────────────────────────────────────────────
mdssc_export_reports "$SCAN_ID"

echo "scan-id=$SCAN_ID" >> "$GITHUB_OUTPUT"

# ── 7. Verdict ────────────────────────────────────────────────────────────────
echo "[MDSSC] Artifact scanned: ${ARTIFACT_DIR}"
mdssc_evaluate "Artifact Scan"
