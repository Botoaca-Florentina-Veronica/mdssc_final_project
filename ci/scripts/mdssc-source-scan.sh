#!/usr/bin/env bash
# MDSSC source code scan — bazat pe scan-source.sh original
#
# Flux (identic cu scan-source.sh):
#   require_env → health → resolve_workflow → arhivare sursă →
#   scan_direct (arhivă) → poll → detalii → (scan indirect opțional) →
#   export_reports (SBOM/PDF/CSV) → evaluate (verdict)
#
# Logica MDSSC e în lib.sh (echivalent mdsscAdvanced.groovy).
# Fallback la mock dacă MDSSC e indisponibil.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARCHIVE="scan-results/mdssc-source-scan.tar.gz"
cleanup() { rm -f "$ARCHIVE"; }
trap cleanup EXIT

# ── Fallback mock ─────────────────────────────────────────────────────────────
use_mock() {
    echo "::warning::${1} — fallback la rezultat mock (pipeline continuă)"
    cat > scan-results/source-scan.json <<'EOF'
{
  "id": "mock-src-fallback",
  "status": "COMPLETED",
  "mock": true,
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0 },
  "secrets": 0,
  "malware": 0
}
EOF
    echo "passed=true"                >> "$GITHUB_OUTPUT"
    echo "scan-id=mock-src-fallback"  >> "$GITHUB_OUTPUT"
    exit 0
}

# ── 0. Validare env + health ──────────────────────────────────────────────────
mdssc_require_env || use_mock "MDSSC credentials lipsesc"
mdssc_health      || use_mock "MDSSC inaccesibil"

# ── 1. Resolve workflow ───────────────────────────────────────────────────────
mdssc_resolve_workflow

# ── 2. Arhivare sursă ─────────────────────────────────────────────────────────
# Acest repo conține: .github/, ci/, e2e/, docs/, README.md
# Excludem: artefacte generate la runtime, dependențe npm, rapoarte Playwright
echo "[MDSSC] Creare arhivă sursă (repo: ${GITHUB_REPOSITORY:-mdssc_final_project})..."
tar czf "$ARCHIVE" \
    --exclude='.git'                    \
    --exclude='e2e/node_modules'        \
    --exclude='e2e/playwright-report'   \
    --exclude='e2e/test-results'        \
    --exclude='e2e/package-lock.json'   \
    --exclude='scan-results'            \
    --exclude='plugin'                  \
    --exclude='artifacts'               \
    --exclude='docs/pipeline-report.json' \
    --exclude='*.log'                   \
    --exclude='*.env'                   \
    --exclude='.env'                    \
    . || { RC=$?; [[ $RC -eq 1 ]] || exit $RC; }
echo "[MDSSC] Dimensiune arhivă: $(du -sh "$ARCHIVE" | cut -f1)"
echo "[MDSSC] Conținut arhivă (top-level):"
tar tzf "$ARCHIVE" | awk -F/ 'NF==2{print "  "$0}' | head -30

# ── 3. Scan direct (upload arhivă) ────────────────────────────────────────────
SCAN_ID=$(mdssc_scan_direct "$ARCHIVE") || use_mock "Upload MDSSC eșuat — răspuns invalid sau endpoint indisponibil"

# ── 4. Poll overview ──────────────────────────────────────────────────────────
mdssc_poll_overview "$SCAN_ID"
MDSSC_DIRECT_OVERVIEW="$MDSSC_OVERVIEW"    # salvat înainte de scanul indirect

# ── 5. Detalii scan ───────────────────────────────────────────────────────────
mdssc_scan_details "$SCAN_ID" "scan-results/source-scan.json"

# ── 6. Scan indirect repo (opțional, informativ) ──────────────────────────────
if [[ "${MDSSC_INDIRECT_SCAN:-false}" == "true" ]]; then
    INDIRECT_ID=$(mdssc_scan_indirect || true)
    [[ -n "${INDIRECT_ID:-}" ]] && mdssc_poll_overview "$INDIRECT_ID" || true
fi

# Restaurează overview-ul direct pentru verdict
MDSSC_OVERVIEW="$MDSSC_DIRECT_OVERVIEW"
MDSSC_SCAN_RESULT=$(cat scan-results/source-scan.json)

# ── 7. Export SBOM + rapoarte ─────────────────────────────────────────────────
mdssc_export_reports "$SCAN_ID"

echo "scan-id=$SCAN_ID" >> "$GITHUB_OUTPUT"

# ── 8. Verdict ────────────────────────────────────────────────────────────────
mdssc_evaluate "Source Scan"
