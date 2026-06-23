// Thin client for the mock MDSSC server's "/_control" plane.
// Lets tests script workflows, connections and scan outcomes, and reset
// state between test cases so scenarios don't leak across runs.
const { BASE_URL } = require("./mock-server-config");

async function post(path, body) {
  const res = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) {
    throw new Error(`mock-control POST ${path} → HTTP ${res.status}`);
  }
  return res.json();
}

function reset() {
  return post("/_control/reset");
}

function setApiKey(value) {
  return post("/_control/api-key", { value });
}

function setServices(services) {
  return post("/_control/services", services);
}

function setReferences(storageId, references) {
  return post(`/_control/references/${storageId}`, references);
}

// workflow: { storageId, repositoryId, repositoryName }
function setWorkflow(id, { storageId = "", repositoryId = "", repositoryName = "" } = {}) {
  return post(`/_control/workflows/${id}`, {
    ScanSources: [
      {
        ServiceId: storageId,
        Repositories: [{ RepositoryId: repositoryId, RepositoryName: repositoryName }],
      },
    ],
  });
}

// Pushes one scripted result onto the FIFO queue consumed by the next
// POST /scans or /scans/direct call.
function scriptScan(scenario) {
  return post("/_control/scan-scenario", scenario);
}

// Makes the next POST /scans or /scans/direct call return the given HTTP
// status (400 by default) — simulates MDSSC rejecting the scan start (e.g.
// invalid branch/connection reference, or an unsupported file type).
function failNextScanStart(status = 400) {
  return post("/_control/fail-next-scan-start", { status });
}

module.exports = {
  BASE_URL,
  reset,
  setApiKey,
  setServices,
  setReferences,
  setWorkflow,
  scriptScan,
  failNextScanStart,
};
