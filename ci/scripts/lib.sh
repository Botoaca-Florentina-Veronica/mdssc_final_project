#!/usr/bin/env bash
# ci/scripts/lib.sh — common MDSSC functions
# Bash equivalent of mdsscAdvanced.groovy from the Jenkinsfile.
# Sourced by mdssc-source-scan.sh and mdssc-artifact-scan.sh.
#
# State variables set by the functions (read by the caller):
#   MDSSC_WF_ID, MDSSC_WF_STORAGE_ID, MDSSC_WF_REPOSITORY_ID
#   MDSSC_OVERVIEW, MDSSC_SCAN_RESULT

# ── Variables with default values ─────────────────────────────────────────────
MDSSC_INSTANCE="${MDSSC_INSTANCE:-}"
MDSSC_INSTANCE="${MDSSC_INSTANCE%/}"   # strip trailing slash
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

# Internal state — set by the functions
MDSSC_WF_ID=""
MDSSC_WF_STORAGE_ID=""
MDSSC_WF_REPOSITORY_ID=""
MDSSC_OVERVIEW=""
MDSSC_SCAN_RESULT=""

mkdir -p scan-results

# ── Internal curl helper ──────────────────────────────────────────────────────
_curl() {
    curl -sf -H "${MDSSC_API_KEY_HEADER}: ${MDSSC_API_KEY}" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_require_env
#   Checks whether MDSSC_INSTANCE and MDSSC_API_KEY are set.
#   Returns 1 (non-fatal) if missing — the caller decides on a fallback.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_require_env() {
    if [[ -z "$MDSSC_INSTANCE" || -z "$MDSSC_API_KEY" ]]; then
        echo "::warning::MDSSC_INSTANCE / MDSSC_API_KEY are not set"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_health
#   GET /version (primary, as in the original scan-source.sh)
#   GET /api/v1/health (fallback per README)
#   Returns 1 if the instance is not reachable.
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
#   GET /api/v1/workflows       — auto-detect if MDSSC_WORKFLOW_ID is empty
#   GET /api/v1/workflows/{id}  — fetch storageId + repositoryId
#   Sets: MDSSC_WF_ID, MDSSC_WF_STORAGE_ID, MDSSC_WF_REPOSITORY_ID
# ─────────────────────────────────────────────────────────────────────────────
mdssc_resolve_workflow() {
    echo "::group::Resolving workflow"
    MDSSC_WF_ID="$MDSSC_WORKFLOW_ID"

    if [[ -z "$MDSSC_WF_ID" ]]; then
        echo "MDSSC_WORKFLOW_ID not found — auto-detecting default workflow..."
        local list
        list=$(_curl "${MDSSC_INSTANCE}/api/v1/workflows") || true
        MDSSC_WF_ID=$(echo "$list" | jq -r '.[0].id // ""')
        echo "Auto-detected workflow: ${MDSSC_WF_ID:-<none>}"
    fi

    if [[ -n "$MDSSC_WF_ID" ]]; then
        local meta
        meta=$(_curl "${MDSSC_INSTANCE}/api/v1/workflows/${MDSSC_WF_ID}") || true
        MDSSC_WF_STORAGE_ID=$(echo "$meta"    | jq -r '.storageId    // ""')
        MDSSC_WF_REPOSITORY_ID=$(echo "$meta" | jq -r '.repositoryId // ""')
    fi

    echo "Workflow ID    : ${MDSSC_WF_ID:-<none>}"
    echo "Storage ID     : ${MDSSC_WF_STORAGE_ID:-<none>}"
    echo "Repository ID  : ${MDSSC_WF_REPOSITORY_ID:-<none>}"
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_direct <file>
#   POST /api/v1/scans/direct — direct upload of a file
#   Returns the scan ID via stdout.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_direct() {
    local file="$1"
    # All messages → stderr, only the scan ID → stdout (captured by the caller via $(...))
    echo "::group::Direct scan: $(basename "$file") ($(du -sh "$file" | cut -f1))" >&2

    local wf_arg=""
    [[ -n "${MDSSC_WF_ID:-}" ]] && wf_arg="-F workflowId=${MDSSC_WF_ID}"

    # Temp file: body and status are captured separately — no risk of mixing the two
    local tmp_resp http_status resp id
    tmp_resp=$(mktemp)
    http_status=$(curl -s \
        -o "$tmp_resp" \
        -w "%{http_code}" \
        -H "${MDSSC_API_KEY_HEADER}: ${MDSSC_API_KEY}" \
        -X POST \
        -F "file=@${file}" \
        ${wf_arg} \
        "${MDSSC_INSTANCE}/api/v1/scans/direct") || true
    resp=$(cat "$tmp_resp")
    rm -f "$tmp_resp"

    echo "HTTP Status : $http_status" >&2
    echo "Response    : $resp"        >&2
    echo "::endgroup::"               >&2

    # Errors visible in the log (outside the collapsed group)
    if [[ "$http_status" != 2* ]]; then
        echo "::error::MDSSC upload failed — HTTP ${http_status} — $(echo "$resp" | head -c 300)"
        return 1
    fi

    # MDSSC returns {"ScanIds":["<uuid>"],...} — not {"id":"<uuid>"}
    id=$(echo "$resp" | jq -r '(.ScanIds[0] // .id) // empty' 2>/dev/null || true)
    if [[ -z "$id" || "$id" == "null" ]]; then
        echo "::error::MDSSC — invalid scan ID — response: $(echo "$resp" | head -c 300)"
        return 1
    fi

    echo "::notice::MDSSC scan started — ID: $id" >&2
    echo "$id"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_indirect
#   POST /api/v1/scans — indirect scan via branch reference (MDSSC pulls from GitHub)
#   Returns the scan ID via stdout.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_indirect() {
    local branch="${GITHUB_REF_NAME:-main}"
    [[ "$branch" == "HEAD" ]] && branch="main"
    local label="${GITHUB_REPOSITORY:-repo}-${branch}"

    # All messages → stderr, only the scan ID → stdout
    echo "::group::Indirect repo scan (branch: $branch)" >&2
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
    id=$(echo "$resp" | jq -r '(.ScanIds[0] // .id) // empty' 2>/dev/null || true)
    echo "Indirect scan ID: $id" >&2
    echo "::endgroup::"          >&2
    echo "$id"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_poll_overview <scan_id>
#   GET /api/v1/scans/{id}/overview — poll until status != IN_PROGRESS
#   Sets: MDSSC_OVERVIEW
# ─────────────────────────────────────────────────────────────────────────────
mdssc_poll_overview() {
    local scan_id="$1"
    echo "::group::Poll $scan_id (timeout: ${MDSSC_SCAN_TIMEOUT}s)"
    local elapsed=0
    local first_iter=true

    while [[ $elapsed -lt $MDSSC_SCAN_TIMEOUT ]]; do
        # Try /overview; if it fails (404 or other HTTP error), fall back to /scans/{id}
        MDSSC_OVERVIEW=$(_curl "${MDSSC_INSTANCE}/api/v1/scans/${scan_id}/overview") || \
            MDSSC_OVERVIEW=$(_curl "${MDSSC_INSTANCE}/api/v1/scans/${scan_id}")      || true

        # First iteration: log the raw response for debugging
        if [[ "$first_iter" == "true" ]]; then
            echo "  [debug] raw response: ${MDSSC_OVERVIEW:0:300}"
            first_iter=false
        fi

        local status
        # Extract the state — identical to Jenkins _overviewParserScript
        # (ScanStatus/scanStatus is a nested object, not a plain string)
        status=$(echo "$MDSSC_OVERVIEW" | jq -r '
            .ScanningState // .scanningState //
            (.scanStatus  |  if type=="object" then .scanningState // .ScanningState else . end) //
            (.ScanStatus  |  if type=="object" then .ScanningState // .scanningState else . end) //
            .status // .Status // .state // .State // empty
        ' 2>/dev/null || true)

        [[ -z "$status" ]] && status="Running"
        echo "  [${elapsed}s] $status"
        # MDSSC uses "Running" (not "IN_PROGRESS") as the active status
        case "$status" in
            Running|RUNNING|IN_PROGRESS|Scanning|SCANNING|Pending|PENDING) ;;
            *) break ;;
        esac

        sleep "$MDSSC_POLL_INTERVAL"
        elapsed=$((elapsed + MDSSC_POLL_INTERVAL))
    done
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_scan_details <scan_id> [out_file]
#   GET /api/v1/scans/{id} — full result
#   Sets: MDSSC_SCAN_RESULT | Writes to out_file
# ─────────────────────────────────────────────────────────────────────────────
mdssc_scan_details() {
    local scan_id="$1"
    local out_file="${2:-scan-results/scan-${scan_id}.json}"
    echo "::group::Scan details: $scan_id"
    MDSSC_SCAN_RESULT=$(_curl "${MDSSC_INSTANCE}/api/v1/scans/${scan_id}")
    echo "$MDSSC_SCAN_RESULT" | jq '.' > "$out_file"
    echo "Saved: $out_file"
    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_export_reports <scan_id>
#   GET /export/{id}/spdx|cyclonedx|pdf|csv
#   Export SBOM and reports into scan-results/
# ─────────────────────────────────────────────────────────────────────────────
mdssc_export_reports() {
    local scan_id="$1"
    echo "::group::Exporting SBOM reports for $scan_id"
    local out_dir="scan-results"

    for fmt in spdx cyclonedx csv; do
        _curl "${MDSSC_INSTANCE}/export/${scan_id}/${fmt}" \
            -o "${out_dir}/${scan_id}-${fmt}.json" 2>/dev/null \
            && echo "  ✓ $fmt → ${out_dir}/${scan_id}-${fmt}.json" \
            || echo "  ⚠ $fmt export unavailable"
    done

    _curl "${MDSSC_INSTANCE}/export/${scan_id}/pdf" \
        -o "${out_dir}/${scan_id}-report.pdf" 2>/dev/null \
        && echo "  ✓ pdf → ${out_dir}/${scan_id}-report.pdf" \
        || echo "  ⚠ pdf export unavailable"

    echo "::endgroup::"
}

# ─────────────────────────────────────────────────────────────────────────────
# mdssc_evaluate <label>
#   Applies the threshold gate on MDSSC_SCAN_RESULT.
#   Writes passed=true/false to GITHUB_OUTPUT.
#   Returns 1 if the scan failed.
# ─────────────────────────────────────────────────────────────────────────────
mdssc_evaluate() {
    local label="${1:-Scan}"
    local result="${MDSSC_SCAN_RESULT:-}"

    # If MDSSC_SCAN_RESULT is invalid, use MDSSC_OVERVIEW as a fallback
    if ! echo "$result" | jq '.' > /dev/null 2>&1; then
        echo "::warning::$label — MDSSC_SCAN_RESULT invalid, using MDSSC_OVERVIEW"
        result="${MDSSC_OVERVIEW:-}"
    fi
    if ! echo "$result" | jq '.' > /dev/null 2>&1; then
        result="{}"
    fi

    local critical high medium low unknown secrets malware blocked_licenses
    # MDSSC API: ScanInformation.VulnerabilityIssues.{critical,high,medium,low,unknown}
    critical=$(echo "$result" | jq -r '
        (.ScanInformation.VulnerabilityIssues.critical //
         .VulnerabilityIssues.critical // .summary.critical // 0)' 2>/dev/null || echo 0)
    high=$(echo "$result" | jq -r '
        (.ScanInformation.VulnerabilityIssues.high //
         .VulnerabilityIssues.high // .summary.high // 0)' 2>/dev/null || echo 0)
    medium=$(echo "$result" | jq -r '
        (.ScanInformation.VulnerabilityIssues.medium //
         .VulnerabilityIssues.medium // .summary.medium // 0)' 2>/dev/null || echo 0)
    low=$(echo "$result" | jq -r '
        (.ScanInformation.VulnerabilityIssues.low //
         .VulnerabilityIssues.low // .summary.low // 0)' 2>/dev/null || echo 0)
    unknown=$(echo "$result" | jq -r '
        (.ScanInformation.VulnerabilityIssues.unknown //
         .VulnerabilityIssues.unknown // .summary.unknown // 0)' 2>/dev/null || echo 0)

    # Malware/Secret are booleans in ScanInformation
    local malware_raw secrets_raw
    malware_raw=$(echo "$result" | jq -r '.ScanInformation.Malware // false' 2>/dev/null || echo false)
    secrets_raw=$(echo "$result" | jq -r '.ScanInformation.Secret  // false' 2>/dev/null || echo false)
    malware=$([[ "$malware_raw" == "true" ]] && echo 1 || echo 0)
    secrets=$([[ "$secrets_raw" == "true" ]] && echo 1 || echo 0)
    # Fall back to int fields if the boolean does not exist
    [[ $malware -eq 0 ]] && malware=$(echo "$result" | jq -r '(.InfectedFiles // .malware // 0)' 2>/dev/null || echo 0)
    [[ $secrets -eq 0 ]] && secrets=$(echo "$result" | jq -r '(.FilesWithSecrets // .secrets // 0)' 2>/dev/null || echo 0)

    blocked_licenses=$(echo "$result" | jq -r '
        (.ScanInformation.Licenses.BlockedLicensesCount //
         .BlockedLicensesCount // 0)' 2>/dev/null || echo 0)

    echo ""
    echo "=========================================="
    echo "   $label — FINAL REPORT"
    echo "=========================================="
    echo "  VULNERABILITIES:"
    echo "  Critical         : $critical"
    echo "  High             : $high"
    echo "  Medium           : $medium"
    echo "  Low              : $low"
    echo "  Unknown          : $unknown"
    echo "------------------------------------------"
    echo "  OTHER FINDINGS:"
    echo "  Secrets          : $secrets"
    echo "  Malware          : $malware"
    echo "  Blocked Licenses : $blocked_licenses"
    echo "------------------------------------------"
    echo "  Threshold        : $VULNERABILITY_THRESHOLD"
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
        echo "::error::$label FAILED — results exceed the configured threshold"
        echo "passed=false" >> "$GITHUB_OUTPUT"
        return 1
    fi

    echo "passed=true" >> "$GITHUB_OUTPUT"
    echo "$label PASSED"
}
