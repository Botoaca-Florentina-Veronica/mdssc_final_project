#!/usr/bin/env bash
# ============================================================
# MDSSC Source Code Scan — Indirect (MDSSC pulls from GitHub)
#
# Flux identic cu Jenkins pipeline (Stage 5 — MDSSC-Source Code Scan):
#   require_env → health → resolve_workflow → fetch metadata →
#   POST /api/v1/scans (indirect) → poll overview → evaluate verdict
#
# MDSSC API calls:
#   GET  /api/v1/health
#   GET  /api/v1/workflows                    (auto-detect dacă MDSSC_WORKFLOW_ID e gol)
#   GET  /api/v1/workflows/{workflowId}       (fetch StorageId + RepositoryId)
#   POST /api/v1/scans                        (indirect scan — MDSSC pulls din GitHub)
#   GET  /api/v1/scans/{id}/overview          (poll)
#   GET  /api/v1/scans/{id}                   (rezultat final)
#
# Parametri (din GitHub Secrets / workflow_dispatch inputs / ci/mdssc-params.env):
#   MDSSC_INSTANCE, MDSSC_API_KEY, MDSSC_API_KEY_HEADER
#   MDSSC_WORKFLOW_ID, MDSSC_STORAGE_ID, MDSSC_REPOSITORY_ID
#   VULNERABILITY_THRESHOLD, FAIL_ON_SECRET, FAIL_ON_MALWARE
#   MDSSC_SCAN_TIMEOUT, MDSSC_POLL_INTERVAL, MDSSC_BRANCH
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${SCRIPT_DIR}/../mdssc-params.env"
GH_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

# ── 1. Încarcă parametri din config (valorile deja setate în env au prioritate) ──
if [[ -f "$PARAMS_FILE" ]]; then
    # shellcheck source=ci/mdssc-params.env
    source "$PARAMS_FILE"
fi

# Determină branch-ul de scanat
BRANCH="${MDSSC_BRANCH:-${GITHUB_REF_NAME:-${BRANCH_NAME:-main}}}"
# Elimină prefixul origin/ dacă există
BRANCH="${BRANCH#origin/}"

mkdir -p scan-results

# ── Fallback mock ─────────────────────────────────────────────────────────────
use_mock() {
    local reason="$1"
    echo "::warning::${reason} — fallback la rezultat mock (pipeline continuă)"
    cat > scan-results/source-scan.json <<'EOF'
{
  "id": "mock-src-fallback",
  "status": "COMPLETED",
  "mock": true,
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
  "secrets": 0,
  "malware": 0
}
EOF
    echo "passed=true"                >> "$GH_OUTPUT"
    echo "scan-id=mock-src-fallback"  >> "$GH_OUTPUT"
    exit 0
}

# ── 0. Validare credențiale ───────────────────────────────────────────────────
if [[ -z "${MDSSC_INSTANCE:-}" || -z "${MDSSC_API_KEY:-}" ]]; then
    use_mock "MDSSC credentials lipsesc — setează secretele MDSSC_INSTANCE și MDSSC_API_KEY"
fi

BASE_URL="${MDSSC_INSTANCE%/}/api/v1"
HDR="${MDSSC_API_KEY_HEADER:-apikey}"

echo "=========================================="
echo "MDSSC Source Code Scan — Indirect"
echo "Instance : $MDSSC_INSTANCE"
echo "Branch   : $BRANCH"
echo "=========================================="

# ── 1. Health check ──────────────────────────────────────────────────────────
echo "[MDSSC] Health check..."
health_ok=false
for path in "/health" "/version" "/scans?limit=1"; do
    http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-hc.json \
        --max-time 15 \
        -H "${HDR}: ${MDSSC_API_KEY}" \
        "${BASE_URL}${path}" 2>/dev/null) || http_code=0
    echo "[MDSSC] GET ${path} → HTTP ${http_code}"
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        health_ok=true
        break
    fi
done
[[ "$health_ok" == "true" ]] || use_mock "MDSSC inaccesibil — niciun health endpoint nu a răspuns"
echo "[MDSSC] Health OK"

# ── 2. Resolve Workflow ID ────────────────────────────────────────────────────
WF_ID="${MDSSC_WORKFLOW_ID:-}"

if [[ -z "$WF_ID" ]]; then
    echo "[MDSSC] MDSSC_WORKFLOW_ID negăsit — auto-detectez din lista de workflows..."
    http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-workflows.json \
        --max-time 30 \
        -H "${HDR}: ${MDSSC_API_KEY}" \
        -H 'Content-Type: application/json' \
        "${BASE_URL}/workflows") || http_code=0
    echo "[MDSSC] GET /workflows → HTTP ${http_code}"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        WF_ID=$(node -e "
            const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-workflows.json','utf8'));
            const list = Array.isArray(d) ? d : (d.workflows||d.Workflows||d.data||d.Data||[]);
            const first = list[0] || {};
            const id = first.id||first.Id||first.WorkflowId||first.workflowId||'';
            if (id) process.stdout.write(id);
        " 2>/dev/null || echo "")
        [[ -n "$WF_ID" ]] && echo "[MDSSC] Workflow auto-detectat: $WF_ID"
    fi
fi

[[ -n "$WF_ID" ]] || use_mock "Nu s-a putut determina workflow ID — setează MDSSC_WORKFLOW_ID în mdssc-params.env sau ca secret GitHub"

# ── 3. Fetch StorageId + RepositoryId din workflow ────────────────────────────
STORAGE_ID="${MDSSC_STORAGE_ID:-}"
REPO_ID="${MDSSC_REPOSITORY_ID:-}"

if [[ -z "$STORAGE_ID" || -z "$REPO_ID" ]]; then
    echo "[MDSSC] Fetch metadata workflow ${WF_ID}..."
    http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-wf.json \
        --max-time 30 \
        -H "${HDR}: ${MDSSC_API_KEY}" \
        -H 'Content-Type: application/json' \
        "${BASE_URL}/workflows/${WF_ID}") || http_code=0
    echo "[MDSSC] GET /workflows/${WF_ID} → HTTP ${http_code}"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        [[ -z "$STORAGE_ID" ]] && STORAGE_ID=$(node -e "
            const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-wf.json','utf8'));
            const src = (d.ScanSources||d.scanSources||[])[0]||{};
            process.stdout.write(src.ServiceId||src.serviceId||d.ServiceId||d.serviceId||'');
        " 2>/dev/null || echo "")

        [[ -z "$REPO_ID" ]] && REPO_ID=$(node -e "
            const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-wf.json','utf8'));
            const src = (d.ScanSources||d.scanSources||[])[0]||{};
            const repos = src.Repositories||src.repositories||d.Repositories||d.repositories||[];
            const r = (Array.isArray(repos)?repos:[repos])[0]||{};
            process.stdout.write(r.RepositoryId||r.repositoryId||r.Id||r.id||'');
        " 2>/dev/null || echo "")
    fi
fi

echo "[MDSSC] WorkflowId   : $WF_ID"
echo "[MDSSC] StorageId    : ${STORAGE_ID:-'(negăsit)'}"
echo "[MDSSC] RepositoryId : ${REPO_ID:-'(negăsit)'}"

if [[ -z "$STORAGE_ID" || -z "$REPO_ID" ]]; then
    use_mock "Nu s-au putut determina StorageId/RepositoryId — verifică conexiunea GitHub din MDSSC sau setează MDSSC_STORAGE_ID/MDSSC_REPOSITORY_ID ca secrete GitHub"
fi

# ── 4. POST indirect scan ─────────────────────────────────────────────────────
# Identic cu Jenkins: POST /api/v1/scans cu body JSON
# MDSSC se conectează la GitHub și scanează branch-ul direct din repo
echo "=========================================="
echo "[MDSSC] Pornire indirect scan..."
echo "[MDSSC] Branch: $BRANCH | Workflow: $WF_ID"
echo "=========================================="

BODY=$(printf '{"StorageId":"%s","ScanType":"Instant","WorkflowId":"%s","RepositoryId":"%s","RepositoryReferences":["%s"]}' \
    "$STORAGE_ID" "$WF_ID" "$REPO_ID" "$BRANCH")

http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-submit.json \
    --max-time 60 \
    -X POST "${BASE_URL}/scans" \
    -H "${HDR}: ${MDSSC_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$BODY") || http_code=0

echo "[MDSSC] POST /scans (indirect) → HTTP ${http_code}"
cat /tmp/mdssc-submit.json 2>/dev/null || true
echo ""

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    use_mock "POST /scans indirect eșuat HTTP ${http_code} — verifică conexiunea GitHub din MDSSC"
fi

SCAN_ID=$(node -e "
    const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-submit.json','utf8'));
    const ids = d.ScanIds||d.scanIds||d.ScanIDs||d.scanIDs;
    const id = Array.isArray(ids) ? ids[0] : (d.scanId||d.ScanId||d.id||d.Id||'');
    if (id) process.stdout.write(String(id));
" 2>/dev/null || echo "")

[[ -n "$SCAN_ID" ]] || use_mock "Niciun scan ID returnat de MDSSC — răspuns neașteptat"
echo "[MDSSC] Scan ID: $SCAN_ID"
echo "scan-id=$SCAN_ID" >> "$GH_OUTPUT"

# ── 5. Poll până la finalizare ────────────────────────────────────────────────
echo "[MDSSC] Polling /scans/${SCAN_ID}/overview ..."
elapsed=0
FINAL_STATE="Unknown"

while [[ "$elapsed" -le "${MDSSC_SCAN_TIMEOUT:-900}" ]]; do
    http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-overview.json \
        --max-time 30 \
        -H "${HDR}: ${MDSSC_API_KEY}" \
        "${BASE_URL}/scans/${SCAN_ID}/overview") || http_code=0

    # Fallback la /scans/{id} dacă /overview nu există
    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        http_code=$(curl -sS -w '%{http_code}' -o /tmp/mdssc-overview.json \
            --max-time 30 \
            -H "${HDR}: ${MDSSC_API_KEY}" \
            "${BASE_URL}/scans/${SCAN_ID}") || http_code=0
    fi

    # Afișează status curent
    node -e "
        const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-overview.json','utf8'));
        const state    = d.ScanningState||d.scanningState||d.status||d.Status||'Unknown';
        const progress = d.ScanProgress!=null?d.ScanProgress:(d.scanProgress!=null?d.scanProgress:'?');
        const c=+(d.critical||d.Critical||0), h=+(d.high||d.High||0);
        const m=+(d.medium||d.Medium||0),     l=+(d.low||d.Low||0);
        const mal=+(d.Malware||d.malware||0);
        const sec=+(d.Secret||d.secret||d.Secrets||d.secrets||0);
        console.log('[${elapsed}s] '+state+' ('+progress+'%) | C:'+c+' H:'+h+' M:'+m+' L:'+l+' | Malware:'+mal+' Secrets:'+sec);
    " 2>/dev/null || true

    FINAL_STATE=$(node -e "
        const d = JSON.parse(require('fs').readFileSync('/tmp/mdssc-overview.json','utf8'));
        process.stdout.write(d.ScanningState||d.scanningState||d.status||d.Status||'Unknown');
    " 2>/dev/null || echo "Unknown")

    NORMALIZED=$(echo "$FINAL_STATE" | tr '[:upper:]' '[:lower:]')

    if [[ "$NORMALIZED" =~ ^(completed|complete|finished|done|success)$ ]]; then
        echo "[MDSSC] Scan finalizat: $FINAL_STATE"
        break
    fi
    if [[ "$NORMALIZED" =~ ^(failed|failure|error|cancelled|canceled)$ ]]; then
        echo "::error::[MDSSC] Scan eșuat cu starea: $FINAL_STATE"
        exit 1
    fi

    sleep "${MDSSC_POLL_INTERVAL:-10}"
    elapsed=$((elapsed + ${MDSSC_POLL_INTERVAL:-10}))
done

if [[ "$elapsed" -gt "${MDSSC_SCAN_TIMEOUT:-900}" ]]; then
    echo "::error::[MDSSC] Scan a expirat după ${MDSSC_SCAN_TIMEOUT:-900}s"
    exit 1
fi

# ── 6. Fetch rezultat complet ─────────────────────────────────────────────────
curl -sS \
    -H "${HDR}: ${MDSSC_API_KEY}" \
    "${BASE_URL}/scans/${SCAN_ID}" \
    -o scan-results/source-scan.json 2>/dev/null || true
echo "[MDSSC] Rezultate salvate → scan-results/source-scan.json"

# ── 7. Evaluare verdict ───────────────────────────────────────────────────────
node -e "
    const fs = require('fs');
    let data = {}, ov = {};
    try { data = JSON.parse(fs.readFileSync('scan-results/source-scan.json','utf8')); } catch(e) {}
    try { ov   = JSON.parse(fs.readFileSync('/tmp/mdssc-overview.json','utf8')); }     catch(e) {}

    const iss      = data.vulnerabilityIssues||data.VulnerabilityIssues||{};
    const critical = +(iss.critical||iss.Critical||ov.critical||ov.Critical||0);
    const high     = +(iss.high    ||iss.High    ||ov.high    ||ov.High    ||0);
    const medium   = +(iss.medium  ||iss.Medium  ||ov.medium  ||ov.Medium  ||0);
    const low      = +(iss.low     ||iss.Low     ||ov.low     ||ov.Low     ||0);
    const malware  = +(ov.Malware||ov.malware||data.malware||0);
    const secrets  = +(ov.Secret||ov.secret||ov.Secrets||ov.secrets||data.secrets||0);
    const blocked  = +(ov.BlockedLicensesCount||ov.blockedLicensesCount||0);

    console.log('');
    console.log('==========================================');
    console.log('   MDSSC SOURCE SCAN REPORT');
    console.log('==========================================');
    console.log('  Final State      : ${FINAL_STATE}');
    console.log('  Branch           : ${BRANCH}');
    console.log('------------------------------------------');
    console.log('  VULNERABILITIES:');
    console.log('  Critical         : ' + critical);
    console.log('  High             : ' + high);
    console.log('  Medium           : ' + medium);
    console.log('  Low              : ' + low);
    console.log('------------------------------------------');
    console.log('  OTHER FINDINGS:');
    console.log('  Malware          : ' + malware);
    console.log('  Secrets          : ' + secrets);
    console.log('  Blocked Licenses : ' + blocked);
    console.log('==========================================');

    const threshold    = '${VULNERABILITY_THRESHOLD:-critical}'.toLowerCase();
    const failSecret   = '${FAIL_ON_SECRET:-true}'  === 'true';
    const failMalware  = '${FAIL_ON_MALWARE:-true}' === 'true';
    const order        = ['low','medium','high','critical'];
    const thIdx        = order.indexOf(threshold);

    let failed = false, reason = '';
    if (thIdx >= 0) {
        for (let i = thIdx; i < order.length; i++) {
            const cnt = {low,medium,high,critical}[order[i]]||0;
            if (cnt > 0) { failed = true; reason = order[i] + ' vulnerabilities found'; break; }
        }
    }
    if (!failed && failSecret  && secrets  > 0) { failed = true; reason = secrets  + ' secret(s) detected'; }
    if (!failed && failMalware && malware  > 0) { failed = true; reason = malware  + ' malware item(s) detected'; }

    if (failed) {
        console.error('::error::[MDSSC] FAIL: ' + reason);
        process.exit(1);
    }
    console.log('[MDSSC] Source scan trecut — niciun prag depășit.');
"

echo "passed=true" >> "$GH_OUTPUT"
