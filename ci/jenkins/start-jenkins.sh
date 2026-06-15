#!/usr/bin/env bash
#
# ci/jenkins/start-jenkins.sh
# ─────────────────────────────────────────────────────────────────────────────
# Pornește o instanță Jenkins Docker temporară, instalează plugin-ul
# mdssc-scanner.hpi, rulează Jenkinsfile.test și raportează rezultatul.
#
# Variabile de mediu necesare (din GitHub Secrets):
#   MDSSC_INSTANCE  — URL instanța MDSSC (ex: http://35.156.106.42)
#   MDSSC_API_KEY   — Cheia API MDSSC
#   HPI_FILE        — Calea locală către .hpi construit
#                     (implicit: <repo>/plugin-out/mdssc-plugin.hpi)
#
# Ieșire:
#   exit 0 — build Jenkins SUCCESS
#   exit 1 — build FAILURE sau timeout
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

# ── Cleanup la ieșire ─────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "[jenkins-test] Salvare loguri container..."
    docker logs "$CONTAINER" > "${LOG_DIR}/jenkins-container.log" 2>&1 || true
    echo "[jenkins-test] Oprire container ${CONTAINER}..."
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

# ── Validare prerequisite ─────────────────────────────────────────────────────
[[ -f "$HPI_FILE" ]] || { echo "ERROR: Fișierul .hpi nu există la: ${HPI_FILE}"; exit 1; }
[[ -n "${MDSSC_INSTANCE:-}" ]] || { echo "ERROR: MDSSC_INSTANCE nu este setat"; exit 1; }
[[ -n "${MDSSC_API_KEY:-}" ]]  || { echo "ERROR: MDSSC_API_KEY nu este setat"; exit 1; }

# ── Helper: curl cu autentificare Jenkins + cookie jar (necesar pentru CSRF) ──
jcurl() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# ── Helper: așteptare Jenkins ready ──────────────────────────────────────────
wait_for_jenkins() {
    local max_wait=240
    local elapsed=0
    echo "[jenkins-test] Aștept Jenkins la ${JENKINS_URL}..."
    while [[ $elapsed -lt $max_wait ]]; do
        if jcurl "${JENKINS_URL}/api/json" -o /dev/null 2>/dev/null; then
            echo "[jenkins-test] Jenkins ready după ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        [[ $((elapsed % 30)) -eq 0 ]] && echo "  ...${elapsed}s"
    done
    echo "ERROR: Jenkins nu a pornit în ${max_wait}s"
    docker logs "$CONTAINER" 2>/dev/null | tail -30
    return 1
}

# ── 1. Pornire Jenkins ────────────────────────────────────────────────────────
echo ""
echo "[1/7] Pornire Jenkins Docker (jenkins/jenkins:lts-jdk17)..."

docker run -d \
    --name "$CONTAINER" \
    -p "${JENKINS_PORT}:8080" \
    -e "JAVA_OPTS=-Djenkins.install.runSetupWizard=false" \
    -e "CASC_JENKINS_CONFIG=/var/casc/jenkins.yaml" \
    -e "MDSSC_INSTANCE=${MDSSC_INSTANCE}" \
    -e "MDSSC_API_KEY=${MDSSC_API_KEY}" \
    -v "${SCRIPT_DIR}/jenkins.yaml:/var/casc/jenkins.yaml:ro" \
    -v "${SCRIPT_DIR}/plugins.txt:/tmp/plugins.txt:ro" \
    -v "${HPI_FILE}:/tmp/mdssc-scanner.hpi:ro" \
    jenkins/jenkins:lts-jdk17

echo "[jenkins-test] Container pornit: ${CONTAINER}"

# Scurt delay ca Jenkins să scrie fișierele inițiale înainte de instalare plugins
sleep 10

# ── 2. Instalare dependențe plugin ────────────────────────────────────────────
echo ""
echo "[2/7] Instalare dependențe plugin via jenkins-plugin-cli..."
docker exec "$CONTAINER" jenkins-plugin-cli \
    --plugin-file /tmp/plugins.txt \
    2>&1 | tee "${LOG_DIR}/plugin-install.log" | grep -E "(Installed|Skipped|ERROR|error)" || true
echo "[jenkins-test] Dependențe instalate."

# ── 3. Instalare plugin MDSSC ─────────────────────────────────────────────────
echo ""
echo "[3/7] Instalare mdssc-scanner.hpi în Jenkins..."
docker exec "$CONTAINER" bash -c 'cp /tmp/mdssc-scanner.hpi "$JENKINS_HOME/plugins/mdssc-scanner.hpi"'
echo "[jenkins-test] Plugin copiat în \$JENKINS_HOME/plugins/"

# ── 4. Restart Jenkins ────────────────────────────────────────────────────────
echo ""
echo "[4/7] Restart Jenkins (activare plugin-uri + JCasC)..."
docker restart "$CONTAINER"

# ── 5. Așteptare Jenkins ready ────────────────────────────────────────────────
echo ""
echo "[5/7] Aștept Jenkins să fie ready (cu auth + JCasC activ)..."
wait_for_jenkins

# Verificare că plugin-ul MDSSC s-a încărcat
echo "[jenkins-test] Verificare plugin MDSSC încărcat..."
docker exec "$CONTAINER" bash -c '
    ls -la "$JENKINS_HOME/plugins/" | grep -i mdssc || echo "  (plugin mdssc nu apare în listing)"
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
        print('  WARN: plugin mdssc-scanner nu apare în lista Jenkins (poate necesită reload)')
except Exception as e:
    print(f'  (nu s-a putut interoga pluginManager: {e})')
" 2>/dev/null || echo "  (verificare plugin indisponibilă)")
echo "$PLUGIN_INFO"

# ── 6. Creare job Pipeline ────────────────────────────────────────────────────
echo ""
echo "[6/7] Creare job pipeline 'mdssc-plugin-test'..."

# Obține CSRF crumb și construiește array de argumente curl
CRUMB=$(jcurl "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('crumb',''))" 2>/dev/null || echo "")
echo "[jenkins-test] CSRF crumb: ${CRUMB:-(none)}"

# Array bash — singura metodă corectă pentru argumente opționale cu spații
CRUMB_ARGS=()
[[ -n "$CRUMB" ]] && CRUMB_ARGS=(-H "Jenkins-Crumb: ${CRUMB}")

# Generează XML job cu Jenkinsfile.test embedded (Python face XML escaping corect)
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

echo "[jenkins-test] XML generat ($(wc -c < "$TMP_JOB_XML") bytes)"

# POST job config — fără -f ca să capturăm codul HTTP real (nu 0)
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
    echo "[jenkins-test] Job creat cu succes"
else
    echo "ERROR: Nu s-a putut crea job-ul — HTTP ${HTTP_CODE}"
    exit 1
fi

# Pornire build
echo "[jenkins-test] Pornire build..."
BUILD_HTTP=$(curl -s -w '%{http_code}' -o /dev/null \
    -X POST "${JENKINS_URL}/job/mdssc-plugin-test/build" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "${CRUMB_ARGS[@]}" 2>/dev/null)
echo "[jenkins-test] build trigger → HTTP ${BUILD_HTTP}"
[[ "$BUILD_HTTP" -ge 200 && "$BUILD_HTTP" -lt 300 ]] || \
    { echo "ERROR: Nu s-a putut porni build-ul — HTTP ${BUILD_HTTP}"; exit 1; }

echo "[jenkins-test] Build pornit. Polling rezultat..."

# ── 7. Poll rezultat ──────────────────────────────────────────────────────────
echo ""
echo "[7/7] Polling build result (max 30 min)..."

BUILD_URL="${JENKINS_URL}/job/mdssc-plugin-test/1"
MAX_POLLS=180   # 180 * 10s = 30 min

# Așteptăm apariția build-ului #1
echo "[jenkins-test] Aștept apariția build-ului..."
for i in $(seq 1 30); do
    if jcurl "${BUILD_URL}/api/json" -o /dev/null 2>/dev/null; then
        break
    fi
    sleep 5
done

POLL=0
while [[ $POLL -lt $MAX_POLLS ]]; do
    BUILD_JSON=$(jcurl "${BUILD_URL}/api/json" 2>/dev/null || echo "{}")

    RESULT=$(echo "$BUILD_JSON" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result') or 'RUNNING')" \
        2>/dev/null || echo "UNKNOWN")

    DURATION_S=$(echo "$BUILD_JSON" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d.get('duration',0)/1000))" \
        2>/dev/null || echo "?")

    echo "  [$(( POLL * 10 ))s] ${RESULT} (durata: ${DURATION_S}s)"

    if [[ "$RESULT" != "RUNNING" && "$RESULT" != "null" && "$RESULT" != "UNKNOWN" ]]; then
        echo ""
        echo "Build finalizat cu rezultatul: ${RESULT}"
        break
    fi

    sleep 10
    POLL=$((POLL + 1))
done

# Salvare console output
echo ""
echo "[jenkins-test] Salvare console output..."
jcurl "${BUILD_URL}/consoleText" > "${LOG_DIR}/build-console.txt" 2>/dev/null || \
    echo "(console output indisponibil)" > "${LOG_DIR}/build-console.txt"

# Afișare ultimele 80 de linii din console
echo ""
echo "── Console Output Jenkins (ultimele 80 linii) ──────────────────────────"
tail -80 "${LOG_DIR}/build-console.txt" 2>/dev/null || true
echo "────────────────────────────────────────────────────────────────────────"
echo ""

if [[ $POLL -ge $MAX_POLLS ]]; then
    echo "ERROR: Timeout — build nu s-a finalizat în 30 de minute"
    exit 1
fi

if [[ "${RESULT:-UNKNOWN}" == "SUCCESS" ]]; then
    echo "✓ MDSSC Plugin Integration Test PASSED"
    exit 0
else
    echo "✗ MDSSC Plugin Integration Test FAILED (result: ${RESULT})"
    exit 1
fi
