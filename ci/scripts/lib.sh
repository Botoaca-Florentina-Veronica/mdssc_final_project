#!/usr/bin/env bash
# ci/scripts/lib.sh — funcții comune MDSSC
# Echivalent bash al mdsscAdvanced.groovy din Jenkinsfile.
# Sourced de mdssc-source-scan.sh și mdssc-artifact-scan.sh.
#
# Variabile de stare setate de funcții (read de caller):
#   MDSSC_WF_ID, MDSSC_WF_STORAGE_ID, MDSSC_WF_REPOSITORY_ID
#   MDSSC_OVERVIEW, MDSSC_SCAN_RESULT

# ── Variabile cu valori implicite ─────────────────────────────────────────────
MDSSC_INSTANCE="${MDSSC_INSTANCE:-}"
MDSSC_API_KEY="${MDSSC_API_KEY:-}"
MDSSC_API_KEY_HEADER="${MDSSC_API_KEY_HEADER:-apikey}"
MDSSC_WORKFLOW_ID="${MDSSC_WORKFLOW_ID:-}"
VULNERABILITY_THRESHOLD="${VULNERABILITY_THRESHOLD:-critical}"
FAIL_ON_SECRET="${FAIL_ON_SECRET:-true}"
FAIL_ON_MALWARE="${FAIL_ON_MALWARE:-true}"
MDSSC_SCAN_TIMEOUT="${MDSSC_SCAN_TIMEOUT:-900}"
MDSSC_POLL_INTERVAL="${MDSSC_POLL_INTERVAL:-10}"
MDSSC_MAX_UPLOAD_MB="${MDSSC_MAX_UPLOAD_MB:-100}"
MDSSC_SKIP_LARGE_ARTIFACTS="${MDSSC_SKIP_LARGE_ARTIFACTS:-true}"
MDSSC_INDIRECT_SCAN="${MDSSC_INDIRECT_SCAN:-false}"

# Stare internă — setată de funcții
MDSSC_WF_ID=""
MDSSC_WF_STORAGE_ID=""
MDSSC_WF_REPOSITORY_ID=""
MDSSC_OVERVIEW=""
MDSSC_SCAN_RESULT=""

mkdir -p scan-results

# ── Helper intern curl ────────────────────────────────────────────────────────
_curl() {
    curl -sf -H "${MDSSC_API_KEY_HEADER}: ${MDSSC_API_KEY}" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_require_env
#   Verifică dacă MDSSC_INSTANCE și MDSSC_API_KEY sunt setate.
#   Returnează 1 (ne-fatal) dacă lipsesc — caller-ul decide fallback.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_require_env() {
    if [[ -z "$MDSSC_INSTANCE" || -z "$MDSSC_API_KEY" ]]; then
        echo "::warning::MDSSC_INSTANCE / MDSSC_API_KEY nu sunt setate"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_health
#   GET /version (primar, ca în scan-source.sh original)
#   GET /api/v1/health (fallback conform README)
#   Returnează 1 dacă instanța nu e accesibilă.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_health() {
    echo "::group::MDSSC health check"
    local status

    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "${MDSSC_API_KEY_HEADER}: ${MDSSC_API_KEY}" \
        "${MDSSC_INSTANCE}/version") || true

    if [[ "$status" != "200" ]]; then
        status=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "${MDSSC_API_KEY_HEADER}: ${MDSSC_API_KEY}" \
            "${MDSSC_INSTANCE}/api/v1/health") || true
    fi

    echo "Health: HTTP $status"
    echo "::endgroup::"
    [[ "$status" == "200" ]] && return 0 || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_resolve_workflow
#   GET /api/v1/workflows       — auto-detectează dacă MDSSC_WORKFLOW_ID e gol
#   GET /api/v1/workflows/{id}  — preia storageId + repositoryId
#   Setează: MDSSC_WF_ID, MDSSC_WF_STORAGE_ID, MDSSC_WF_REPOSITORY_ID
# ─────────────────────────────────────────────────────────────────────────────
mdssc_resolve_workflow() {
    echo "::group::Rezolvare workflow"
    MDSSC_WF_ID="$MDSSC_WORKFLOW_ID"

    if [[ -z "$MDSSC_WF_ID" ]]; then
        echo "MDSSC_WORKFLOW_ID negăsit — auto-detectare workflow implicit..."
        local list
        list=$(_curl "${MDSSC_INSTANCE}/api/v1/workflows") || true
        MDSSC_WF_ID=$(echo "$list" | jq -r '.[0].id // ""')
        echo "Workflow auto-detectat: ${MDSSC_WF_ID:-<niciunul>}"
    fi

    if [[ -n "$MDSSC_WF_ID" ]]; then
        local meta
        meta=$(_curl "${MDSSC_INSTANCE}/api/v1/workflows/${MDSSC_WF_ID}") || true
        MDSSC_WF_STORAGE_ID=$(echo "$meta"    | jq -r '.storageId    // ""')
        MDSSC_WF_REPOSITORY_ID=$(echo "$meta" | jq -r '.repositoryId // ""')
    fi

    echo "Workflow ID    : ${MDSSC_WF_ID:-<niciunul>}"
    echo "Storage ID     : ${MDSSC_WF_STORAGE_ID:-<niciunul>}"
    echo "Repository ID  : ${MDSSC_WF_REPOSITORY_ID:-<niciunul>}"
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_direct <file>
#   POST /api/v1/scans/direct — upload direct al unui fișier
#   Returnează scan ID prin stdout.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_direct() {
    local file="$1"
    # Toate mesajele → stderr, doar scan ID → stdout (capturat de caller cu $(...))
    echo "::group::Scan direct: $(basename "$file") ($(du -sh "$file" | cut -f1))" >&2
    local resp id
    resp=$(_curl -X POST \
        -F "file=@${file}" \
        "${MDSSC_INSTANCE}/api/v1/scans/direct")
    id=$(echo "$resp" | jq -r '.id')
    echo "Scan ID: $id" >&2
    echo "::endgroup::"                >&2
    echo "$id"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_indirect
#   POST /api/v1/scans — scan indirect prin referință branch (MDSSC trage din GitHub)
#   Returnează scan ID prin stdout.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_indirect() {
    local branch="${GITHUB_REF_NAME:-main}"
    [[ "$branch" == "HEAD" ]] && branch="main"
    local label="${GITHUB_REPOSITORY:-repo}-${branch}"

    # Toate mesajele → stderr, doar scan ID → stdout
    echo "::group::Scan indirect repo (branch: $branch)" >&2
    local payload resp id
    payload=$(jq -n \
        --arg wf  "$MDSSC_WF_ID" \
        --arg sid "$MDSSC_WF_STORAGE_ID" \
        --arg rid "$MDSSC_WF_REPOSITORY_ID" \
        --arg br  "$branch" \
        --arg lbl "$label" \
        '{workflowId:$wf, storageId:$sid, repositoryId:$rid, branch:$br, label:$lbl}')
    resp=$(_curl -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${MDSSC_INSTANCE}/api/v1/scans")
    id=$(echo "$resp" | jq -r '.id')
    echo "Indirect scan ID: $id" >&2
    echo "::endgroup::"          >&2
    echo "$id"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_poll_overview <scan_id>
#   GET /api/v1/scans/{id}/overview — poll până status != IN_PROGRESS
#   Setează: MDSSC_OVERVIEW
# ─────────────────────────────────────────────────────────────────────────────
mdssc_poll_overview() {
    local scan_id="$1"
    echo "::group::Poll $scan_id (timeout: ${MDSSC_SCAN_TIMEOUT}s)"
    local elapsed=0
    while [[ $elapsed -lt $MDSSC_SCAN_TIMEOUT ]]; do
        MDSSC_OVERVIEW=$(_curl "${MDSSC_INSTANCE}/api/v1/scans/${scan_id}/overview")
        local status
        status=$(echo "$MDSSC_OVERVIEW" | jq -r '.status')
        echo "  [${elapsed}s] $status"
        [[ "$status" != "IN_PROGRESS" ]] && break
        sleep "$MDSSC_POLL_INTERVAL"
        elapsed=$((elapsed + MDSSC_POLL_INTERVAL))
    done
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_details <scan_id> [out_file]
#   GET /api/v1/scans/{id} — rezultat complet
#   Setează: MDSSC_SCAN_RESULT | Scrie în out_file
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_details() {
    local scan_id="$1"
    local out_file="${2:-scan-results/scan-${scan_id}.json}"
    echo "::group::Detalii scan: $scan_id"
    MDSSC_SCAN_RESULT=$(_curl "${MDSSC_INSTANCE}/api/v1/scans/${scan_id}")
    echo "$MDSSC_SCAN_RESULT" | jq '.' > "$out_file"
    echo "Salvat: $out_file"
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_export_reports <scan_id>
#   GET /export/{id}/spdx|cyclonedx|pdf|csv
#   Export SBOM și rapoarte în scan-results/
# ─────────────────────────────────────────────────────────────────────────────
mdssc_export_reports() {
    local scan_id="$1"
    echo "::group::Export rapoarte SBOM pentru $scan_id"
    local out_dir="scan-results"

    for fmt in spdx cyclonedx csv; do
        _curl "${MDSSC_INSTANCE}/export/${scan_id}/${fmt}" \
            -o "${out_dir}/${scan_id}-${fmt}.json" 2>/dev/null \
            && echo "  ✓ $fmt → ${out_dir}/${scan_id}-${fmt}.json" \
            || echo "  ⚠ $fmt export indisponibil"
    done

    _curl "${MDSSC_INSTANCE}/export/${scan_id}/pdf" \
        -o "${out_dir}/${scan_id}-report.pdf" 2>/dev/null \
        && echo "  ✓ pdf → ${out_dir}/${scan_id}-report.pdf" \
        || echo "  ⚠ pdf export indisponibil"

    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_evaluate <label>
#   Aplică gate-ul de threshold pe MDSSC_SCAN_RESULT.
#   Scrie passed=true/false în GITHUB_OUTPUT.
#   Returnează 1 dacă scan-ul a picat.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_evaluate() {
    local label="${1:-Scan}"
    local result="${MDSSC_SCAN_RESULT:-{}}"

    local critical high medium low unknown secrets malware
    critical=$(echo "$result" | jq -r '.summary.critical // 0')
    high=$(echo "$result"     | jq -r '.summary.high     // 0')
    medium=$(echo "$result"   | jq -r '.summary.medium   // 0')
    low=$(echo "$result"      | jq -r '.summary.low      // 0')
    unknown=$(echo "$result"  | jq -r '.summary.unknown  // 0')
    secrets=$(echo "$result"  | jq -r '.secrets          // 0')
    malware=$(echo "$result"  | jq -r '.malware          // 0')

    echo ""
    echo "=========================================="
    echo "   $label — RAPORT FINAL"
    echo "=========================================="
    echo "  Critical : $critical"
    echo "  High     : $high"
    echo "  Medium   : $medium"
    echo "  Low      : $low"
    echo "  Unknown  : $unknown"
    echo "  Secrets  : $secrets"
    echo "  Malware  : $malware"
    echo "  Threshold: $VULNERABILITY_THRESHOLD"
    echo "=========================================="

    local failed=false
    case "$VULNERABILITY_THRESHOLD" in
        none)    ;;
        unknown) [[ $unknown -gt 0 || $low -gt 0 || $medium -gt 0 || $high -gt 0 || $critical -gt 0 ]] && failed=true ;;
        low)     [[ $low     -gt 0 || $medium -gt 0 || $high -gt 0 || $critical -gt 0 ]] && failed=true ;;
        medium)  [[ $medium  -gt 0 || $high -gt 0 || $critical -gt 0 ]] && failed=true ;;
        high)    [[ $high    -gt 0 || $critical -gt 0 ]] && failed=true ;;
        critical)[[ $critical -gt 0 ]] && failed=true ;;
    esac
    [[ "$FAIL_ON_SECRET"  == "true" && $secrets -gt 0 ]] && failed=true
    [[ "$FAIL_ON_MALWARE" == "true" && $malware -gt 0 ]] && failed=true

    if [[ "$failed" == "true" ]]; then
        echo "::error::$label PICAT — rezultate depășesc threshold-ul configurat"
        echo "passed=false" >> "$GITHUB_OUTPUT"
        return 1
    fi

    echo "passed=true" >> "$GITHUB_OUTPUT"
    echo "$label TRECUT"
}
