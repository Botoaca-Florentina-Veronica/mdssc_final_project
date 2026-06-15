#!/usr/bin/env bash
#
# ci/jenkins/run-jenkins-dev.sh
# ─────────────────────────────────────────────────────────────────────────────
# Pornește Jenkins LOCAL cu plugin-ul MDSSC instalat.
# Containerul rămâne activ — accesezi UI-ul la http://localhost:8080
#
# Utilizare:
#   export MDSSC_INSTANCE="http://35.x.x.x"
#   export MDSSC_API_KEY="cheia_ta"
#   bash ci/jenkins/run-jenkins-dev.sh
#
# Credențiale Jenkins UI:
#   User: admin
#   Parolă: admin123
#
# Oprire:
#   docker stop jenkins-mdssc-dev
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HPI_FILE="${HPI_FILE:-${REPO_ROOT}/plugin/target/mdssc-scanner.hpi}"
CONTAINER="jenkins-mdssc-dev"
PORT=8080

echo "=========================================="
echo "  MDSSC Jenkins Dev Instance"
echo "  UI: http://localhost:${PORT}"
echo "  User: admin / Parolă: admin123"
echo "=========================================="

# Verificare prerequisite
[[ -f "$HPI_FILE" ]] || {
    echo "ERROR: .hpi nu există la: ${HPI_FILE}"
    echo "Rulează mai întâi: cd plugin && mvn clean package -DskipTests"
    exit 1
}

# Oprire container existent (dacă există)
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "[dev] Oprire container existent ${CONTAINER}..."
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
fi

COOKIE_JAR=$(mktemp /tmp/jenkins-dev-cookies-XXXXXX.txt)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

jcurl() {
    curl -sf -u "admin:admin123" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# ── 1. Start Jenkins ──────────────────────────────────────────────────────────
echo ""
echo "[1/4] Pornire Jenkins..."
docker run -d \
    --name "$CONTAINER" \
    -p "${PORT}:8080" \
    -e "JAVA_OPTS=-Djenkins.install.runSetupWizard=false" \
    -e "CASC_JENKINS_CONFIG=/var/casc/jenkins.yaml" \
    -e "MDSSC_INSTANCE=${MDSSC_INSTANCE:-}" \
    -e "MDSSC_API_KEY=${MDSSC_API_KEY:-}" \
    -v "${SCRIPT_DIR}/jenkins.yaml:/var/casc/jenkins.yaml:ro" \
    -v "${SCRIPT_DIR}/plugins.txt:/tmp/plugins.txt:ro" \
    jenkins/jenkins:lts-jdk17

# Copiere HPI cu docker cp (evită problemele de path Windows cu volume mounts)
sleep 3
docker cp "${HPI_FILE}" "${CONTAINER}:/tmp/mdssc-scanner.hpi"

# ── 2. Instalare dependențe ───────────────────────────────────────────────────
echo "[2/4] Instalare dependențe plugin..."
docker exec "$CONTAINER" jenkins-plugin-cli --plugin-file /tmp/plugins.txt 2>&1 | \
    grep -E "(Installed|ERROR)" || true
docker exec "$CONTAINER" bash -c 'cp /tmp/mdssc-scanner.hpi "$JENKINS_HOME/plugins/mdssc-scanner.hpi"'

# ── 3. Restart + așteptare ────────────────────────────────────────────────────
echo "[3/4] Restart Jenkins (activare plugin-uri + JCasC)..."
docker restart "$CONTAINER"

echo "[4/4] Aștept Jenkins să pornească..."
for i in $(seq 1 60); do
    if jcurl "http://localhost:${PORT}/api/json" -o /dev/null 2>/dev/null; then
        echo ""
        echo "=========================================="
        echo "  Jenkins READY!"
        echo "  Deschide: http://localhost:${PORT}"
        echo "  User    : admin"
        echo "  Parolă  : admin123"
        echo ""
        echo "  Plugin instalat:"
        jcurl "http://localhost:${PORT}/pluginManager/api/json?depth=1" 2>/dev/null | \
            python3 -c "
import sys, json
plugins = json.load(sys.stdin).get('plugins', [])
m = next((p for p in plugins if 'mdssc' in p.get('shortName','').lower()), None)
if m: print(f'  mdssc-scanner v{m[\"version\"]} — active={m[\"active\"]}')
" 2>/dev/null || true
        echo ""
        echo "  Oprire: docker stop ${CONTAINER}"
        echo "=========================================="
        exit 0
    fi
    sleep 5
    [[ $((i % 6)) -eq 0 ]] && echo "  ...${i}s"
done

echo "ERROR: Jenkins nu a pornit în 5 minute"
exit 1
