#!/usr/bin/env bash
#
# ci/jenkins/start-jenkins.sh
# ─────────────────────────────────────────────────────────────────────────────
# Starts a temporary Jenkins Docker instance, installs the
# mdssc-scanner.hpi plugin, runs Jenkinsfile.test and reports the result.
#
# Required environment variables (from GitHub Secrets):
#   MDSSC_INSTANCE  — MDSSC instance URL (e.g. http://35.156.106.42)
#   MDSSC_API_KEY   — MDSSC API key
#   HPI_FILE        — local path to the built .hpi
#                     (default: <repo>/plugin-out/mdssc-plugin.hpi)
#
# Output:
#   exit 0 — Jenkins build SUCCESS
#   exit 1 — FAILURE or timeout
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HPI_FILE="${HPI_FILE:-${REPO_ROOT}/plugin-out/mdssc-plugin.hpi}"
LOG_DIR="${REPO_ROOT}/jenkins-test-logs"
JENKINS_PORT=18080
JENKINS_URL="http://localhost:${JENKINS_PORT}"
JENKINS_USER="admin"
JENKINS_PASS="admin123"
CONTAINER="jenkins-mdssc-$$"
COOKIE_JAR=$(mktemp /tmp/jenkins-cookies-XXXXXX.txt)

mkdir -p "$LOG_DIR"

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "[jenkins-test] Saving container logs..."
    docker logs "$CONTAINER" > "${LOG_DIR}/jenkins-container.log" 2>&1 || true
    echo "[jenkins-test] Stopping container ${CONTAINER}..."
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

echo "=========================================="
echo "  MDSSC Plugin Integration Test"
echo "  Jenkins : ${JENKINS_URL}"
echo "  Plugin  : ${HPI_FILE}"
echo "=========================================="

# ── Validate prerequisites ────────────────────────────────────────────────────
[[ -f "$HPI_FILE" ]] || { echo "ERROR: .hpi file does not exist at: ${HPI_FILE}"; exit 1; }
[[ -n "${MDSSC_INSTANCE:-}" ]] || { echo "ERROR: MDSSC_INSTANCE is not set"; exit 1; }
[[ -n "${MDSSC_API_KEY:-}" ]]  || { echo "ERROR: MDSSC_API_KEY is not set"; exit 1; }

# ── Helper: curl with Jenkins auth + cookie jar (required for CSRF) ───────────
jcurl() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# ── Helper: wait for Jenkins ready ───────────────────────────────────────────
wait_for_jenkins() {
    local max_wait=240
    local elapsed=0
    echo "[jenkins-test] Waiting for Jenkins at ${JENKINS_URL}..."
    while [[ $elapsed -lt $max_wait ]]; do
        if jcurl "${JENKINS_URL}/api/json" -o /dev/null 2>/dev/null; then
            echo "[jenkins-test] Jenkins ready after ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        [[ $((elapsed % 30)) -eq 0 ]] && echo "  ...${elapsed}s"
    done
    echo "ERROR: Jenkins did not start within ${max_wait}s"
    docker logs "$CONTAINER" 2>/dev/null | tail -30
    return 1
}

# ── 1. Start Jenkins ──────────────────────────────────────────────────────────
echo ""
echo "[1/7] Starting Jenkins Docker (jenkins/jenkins:lts-jdk17)..."

docker run -d \
    --name "$CONTAINER" \
    -p "${JENKINS_PORT}:8080" \
    -e "JAVA_OPTS=-Djenkins.install.runSetupWizard=false" \
    -e "CASC_JENKINS_CONFIG=/var/casc/jenkins.yaml" \
    -e "MDSSC_INSTANCE=${MDSSC_INSTANCE}" \
    -e "MDSSC_API_KEY=${MDSSC_API_KEY}" \
    -e "MDSSC_WORKFLOW_ID=${MDSSC_WORKFLOW_ID:-}" \
    -v "${SCRIPT_DIR}/jenkins.yaml:/var/casc/jenkins.yaml:ro" \
    -v "${SCRIPT_DIR}/plugins.txt:/tmp/plugins.txt:ro" \
    -v "${HPI_FILE}:/tmp/mdssc-scanner.hpi:ro" \
    jenkins/jenkins:lts-jdk17

echo "[jenkins-test] Container started: ${CONTAINER}"

# Short delay so Jenkins writes the initial files before installing plugins
sleep 10

# ── 2. Install plugin dependencies ────────────────────────────────────────────
echo ""
echo "[2/7] Installing plugin dependencies via jenkins-plugin-cli..."
docker exec "$CONTAINER" jenkins-plugin-cli \
    --plugin-file /tmp/plugins.txt \
    2>&1 | tee "${LOG_DIR}/plugin-install.log" | grep -E "(Installed|Skipped|ERROR|error)" || true
echo "[jenkins-test] Dependencies installed."

# ── 3. Install the MDSSC plugin ───────────────────────────────────────────────
echo ""
echo "[3/7] Installing mdssc-scanner.hpi into Jenkins..."
docker exec "$CONTAINER" bash -c 'cp /tmp/mdssc-scanner.hpi "$JENKINS_HOME/plugins/mdssc-scanner.hpi"'
echo "[jenkins-test] Plugin copied into \$JENKINS_HOME/plugins/"

# ── 4. Restart Jenkins ────────────────────────────────────────────────────────
echo ""
echo "[4/7] Restarting Jenkins (activating plugins + JCasC)..."
docker restart "$CONTAINER"

# ── 5. Wait for Jenkins ready ─────────────────────────────────────────────────
echo ""
echo "[5/7] Waiting for Jenkins to be ready (with auth + JCasC active)..."
wait_for_jenkins

# Verify that the MDSSC plugin loaded
echo "[jenkins-test] Verifying MDSSC plugin loaded..."
docker exec "$CONTAINER" bash -c '
    ls -la "$JENKINS_HOME/plugins/" | grep -i mdssc || echo "  (mdssc plugin not shown in listing)"
' 2>/dev/null || true

PLUGIN_INFO=$(jcurl "${JENKINS_URL}/pluginManager/api/json?depth=1" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    plugins = data.get('plugins', [])
    mdssc = next((p for p in plugins if 'mdssc' in p.get('shortName','').lower()), None)
    if mdssc:
        active = mdssc.get('active', False)
        enabled = mdssc.get('enabled', False)
        version = mdssc.get('version', '?')
        print(f'  Plugin: {mdssc[\"shortName\"]} v{version} — active={active} enabled={enabled}')
    else:
        print('  WARN: mdssc-scanner plugin not shown in the Jenkins list (may need a reload)')
except Exception as e:
    print(f'  (could not query pluginManager: {e})')
" 2>/dev/null || echo "  (plugin verification unavailable)")
echo "$PLUGIN_INFO"

# ── 6. Create Pipeline job ────────────────────────────────────────────────────
echo ""
echo "[6/7] Creating pipeline job 'mdssc-plugin-test'..."

# Get the CSRF crumb and build the curl arguments array
CRUMB=$(jcurl "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('crumb',''))" 2>/dev/null || echo "")
echo "[jenkins-test] CSRF crumb: ${CRUMB:-(none)}"

# Bash array — the only correct way for optional arguments with spaces
CRUMB_ARGS=()
[[ -n "$CRUMB" ]] && CRUMB_ARGS=(-H "Jenkins-Crumb: ${CRUMB}")

# Generate job XML with Jenkinsfile.test embedded (Python handles XML escaping correctly)
TMP_JOB_XML=$(mktemp /tmp/mdssc-job-XXXXXX.xml)
python3 - <<PYEOF > "$TMP_JOB_XML"
import xml.sax.saxutils as X

with open('${REPO_ROOT}/Jenkinsfile.test') as f:
    script = f.read()

xml = '''<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>MDSSC Plugin Integration Test — auto-generated by CI</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>{script}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''.format(script=X.escape(script))

print(xml)
PYEOF

echo "[jenkins-test] XML generated ($(wc -c < "$TMP_JOB_XML") bytes)"

# POST job config — without -f so we capture the real HTTP code (not 0)
HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/mdssc-create-resp.txt \
    -X POST "${JENKINS_URL}/createItem?name=mdssc-plugin-test" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "${CRUMB_ARGS[@]}" \
    -H "Content-Type: application/xml" \
    --data-binary "@${TMP_JOB_XML}" 2>/dev/null)
rm -f "$TMP_JOB_XML"

echo "[jenkins-test] createItem → HTTP ${HTTP_CODE}"
[[ -s /tmp/mdssc-create-resp.txt ]] && cat /tmp/mdssc-create-resp.txt && echo ""

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "[jenkins-test] Job created successfully"
else
    echo "ERROR: Could not create the job — HTTP ${HTTP_CODE}"
    exit 1
fi

# Start build
echo "[jenkins-test] Starting build..."
BUILD_HTTP=$(curl -s -w '%{http_code}' -o /dev/null \
    -X POST "${JENKINS_URL}/job/mdssc-plugin-test/build" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "${CRUMB_ARGS[@]}" 2>/dev/null)
echo "[jenkins-test] build trigger → HTTP ${BUILD_HTTP}"
[[ "$BUILD_HTTP" -ge 200 && "$BUILD_HTTP" -lt 300 ]] || \
    { echo "ERROR: Could not start the build — HTTP ${BUILD_HTTP}"; exit 1; }

echo "[jenkins-test] Build started. Polling result..."

# ── 7. Poll result ────────────────────────────────────────────────────────────
echo ""
echo "[7/7] Polling build result (max 30 min)..."

BUILD_URL="${JENKINS_URL}/job/mdssc-plugin-test/1"
MAX_POLLS=180   # 180 * 10s = 30 min

# Wait for build #1 to appear
echo "[jenkins-test] Waiting for the build to appear..."
for i in $(seq 1 30); do
    if jcurl "${BUILD_URL}/api/json" -o /dev/null 2>/dev/null; then
        break
    fi
    sleep 5
done

POLL=0
while [[ $POLL -lt $MAX_POLLS ]]; do
    BUILD_JSON=$(jcurl "${BUILD_URL}/api/json" 2>/dev/null || echo "{}")

    # Check `building` — Jenkins sets result=FAILURE immediately but the build may still be active
    RESULT=$(echo "$BUILD_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
building = d.get('building', False)
result   = d.get('result') or 'null'
duration = int(d.get('duration', 0) / 1000)
if building:
    print('RUNNING|' + str(duration))
else:
    print((result or 'UNKNOWN') + '|' + str(duration))
" 2>/dev/null || echo "UNKNOWN|0")

    STATE="${RESULT%|*}"
    DURATION_S="${RESULT#*|}"

    echo "  [$(( POLL * 10 ))s] ${STATE} (duration: ${DURATION_S}s)"

    if [[ "$STATE" != "RUNNING" && "$STATE" != "null" && "$STATE" != "UNKNOWN" ]]; then
        echo ""
        echo "Build finished with result: ${STATE}"
        RESULT="$STATE"
        break
    fi

    sleep 10
    POLL=$((POLL + 1))
done
RESULT="${RESULT%|*}"

# Save console output
echo ""
echo "[jenkins-test] Saving console output..."
jcurl "${BUILD_URL}/consoleText" > "${LOG_DIR}/build-console.txt" 2>/dev/null || \
    echo "(console output unavailable)" > "${LOG_DIR}/build-console.txt"

# Full console — in a collapsible GitHub Actions section
echo ""
echo "::group::📋 Full Console Output (Jenkins)"
cat "${LOG_DIR}/build-console.txt" 2>/dev/null || true
echo "::endgroup::"

# Extract and print a scan report in its own section
print_scan_report() {
    local label="$1"
    local title="$2"
    echo ""
    echo "::group::${title}"
    awk -v lbl="$label" '
        $0 ~ /MDSSC SCAN REPORT/ && index($0, lbl) {
            inblock = 1
            print "=========================================="
        }
        inblock { print }
        inblock && (/Scan passed all thresholds/ || /MDSSC] FAIL/) { inblock = 0 }
    ' "${LOG_DIR}/build-console.txt" 2>/dev/null || true
    echo "::endgroup::"
}

echo ""
echo "=========================================="
echo "  MDSSC SCAN RESULTS"
echo "=========================================="
print_scan_report "source-code"       "🔍 Source Code Scan — results"
print_scan_report "mdssc-scanner.hpi" "🛡️ Artifact Scan — results"
echo ""

if [[ $POLL -ge $MAX_POLLS ]]; then
    echo "ERROR: Timeout — build did not finish within 30 minutes"
    exit 1
fi

if [[ "${RESULT:-UNKNOWN}" == "SUCCESS" ]]; then
    echo "✓ MDSSC Plugin Integration Test PASSED"
    exit 0
else
    echo "✗ MDSSC Plugin Integration Test FAILED (result: ${RESULT})"
    exit 1
fi
