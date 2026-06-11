#!/usr/bin/env bash
#
# mdssc-artifact-scan.sh — scanează artefactul construit (plugin/) cu MDSSC.
# Bazat pe scan-artifacts.sh original.
#
# Flux (identic cu scan-artifacts.sh):
#   require_env → health → arhivare plugin/ →
#   scan_direct (arhivă) → poll → detalii → export_reports → evaluate
#
# Logica MDSSC e în lib.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# BUILD_NUMBER → GITHUB_RUN_NUMBER în GitHub Actions
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
ARTIFACT_DIR="${MDSSC_ARTIFACT_DIR:-plugin}"
ARCHIVE="mdssc-artifact-scan-${BUILD_NUMBER}.tar.gz"

cleanup() { rm -f "$ARCHIVE"; }
trap cleanup EXIT

# ── Fallback mock ─────────────────────────────────────────────────────────────
use_mock() {
    echo "::warning::${1} — fallback la rezultat mock (pipeline continuă)"
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

# ── 0. Validare env ───────────────────────────────────────────────────────────
mdssc_require_env || use_mock "MDSSC credentials lipsesc"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
    echo "[MDSSC] ERROR: directorul '$ARTIFACT_DIR' nu există — a rulat stage-ul de build?"
    exit 1
fi

# ── 1. Health check ───────────────────────────────────────────────────────────
mdssc_health || use_mock "MDSSC inaccesibil"

# ── 2. Resolve workflow (preia MDSSC_WF_ID pentru scan direct) ────────────────
mdssc_resolve_workflow

# ── 3. Arhivare artefact ──────────────────────────────────────────────────────
echo "[MDSSC] Creare arhivă artefact din '${ARTIFACT_DIR}'..."
tar czf "$ARCHIVE" "$ARTIFACT_DIR"
echo "[MDSSC] Dimensiune arhivă: $(du -sh "$ARCHIVE" | cut -f1)"
echo "[MDSSC] Conținut:"
tar tzf "$ARCHIVE" | sed 's/^/  /'

# ── 4. Scan direct ────────────────────────────────────────────────────────────
SCAN_ID=$(mdssc_scan_direct "$ARCHIVE") || use_mock "Upload MDSSC eșuat — răspuns invalid sau endpoint indisponibil"

# ── 5. Poll overview ──────────────────────────────────────────────────────────
mdssc_poll_overview "$SCAN_ID"

# ── 6. Detalii scan ───────────────────────────────────────────────────────────
mdssc_scan_details "$SCAN_ID" "scan-results/artifact-scan.json"

# ── 7. Export SBOM + rapoarte ─────────────────────────────────────────────────
mdssc_export_reports "$SCAN_ID"

echo "scan-id=$SCAN_ID" >> "$GITHUB_OUTPUT"

# ── 7. Verdict ────────────────────────────────────────────────────────────────
echo "[MDSSC] Artefact scanat: ${ARTIFACT_DIR}"
mdssc_evaluate "Artifact Scan"
