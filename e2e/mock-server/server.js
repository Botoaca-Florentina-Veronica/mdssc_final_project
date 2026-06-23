// Mock MDSSC server — replicates the subset of the real MetaDefender
// Software Supply Chain API consumed by the Jenkins plugin (MdsscApiClient.java)
// and by ci/scripts/lib.sh + mdssc-source-scan.sh.
//
// Response shapes follow plugin.md's documented contract:
//   ScanInformation.VulnerabilityIssues.{critical,high,medium,low,unknown}
//   ScanInformation.Malware / ScanInformation.Secret (booleans)
//   ScanInformation.Licenses.BlockedLicensesCount
//
// A "/_control" plane (not part of the real API) lets tests script
// workflows/services/scan outcomes and reset state between runs.

const express = require("express");
const multer = require("multer");
const crypto = require("crypto");

function defaultScenario() {
  return {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0,
    unknown: 0,
    secret: false,
    malware: false,
    blockedLicenses: 0,
    finalState: "Completed",
    pollsBeforeDone: 0,
  };
}

function createApp() {
  const app = express();
  app.use(express.json());
  const upload = multer();

  const state = {
    apiKey: "mock-api-key",
    services: [],
    references: {},
    workflows: {},
    scanQueue: [],
    scans: {},
    failNextScanStart: null, // null = don't fail; otherwise an HTTP status code
  };

  function resetState() {
    state.apiKey = "mock-api-key";
    state.services = [];
    state.references = {};
    state.workflows = {};
    state.scanQueue = [];
    state.scans = {};
    state.failNextScanStart = null;
  }

  function nextScenario() {
    return state.scanQueue.length ? state.scanQueue.shift() : defaultScenario();
  }

  function buildResultBody(scan, { forceFinal = false } = {}) {
    const running = !forceFinal && scan.pollsRemaining > 0;
    return {
      ScanningState: running ? "Running" : scan.scenario.finalState,
      ScanProgress: running ? 50 : 100,
      ScanInformation: {
        VulnerabilityIssues: {
          critical: scan.scenario.critical || 0,
          high: scan.scenario.high || 0,
          medium: scan.scenario.medium || 0,
          low: scan.scenario.low || 0,
          unknown: scan.scenario.unknown || 0,
        },
        Malware: !!scan.scenario.malware,
        Secret: !!scan.scenario.secret,
        Licenses: { BlockedLicensesCount: scan.scenario.blockedLicenses || 0 },
      },
    };
  }

  function auth(req, res, next) {
    const key = req.get("apikey");
    if (!key || key !== state.apiKey) {
      return res.status(401).json({ error: "invalid or missing API key" });
    }
    next();
  }

  // ── Health (unauthenticated — matches real-world health probe conventions) ──
  app.get("/version", (req, res) => res.json({ version: "mock-mdssc-1.0" }));
  app.get("/api/v1/version", (req, res) => res.json({ version: "mock-mdssc-1.0" }));
  app.get("/api/v1/health", (req, res) => res.json({ status: "ok" }));

  // ── Workflows ──
  app.get("/api/v1/scans", auth, (req, res) => res.json([]));

  app.get("/api/v1/workflows", auth, (req, res) => {
    res.json(Object.keys(state.workflows).map((id) => ({ id })));
  });

  app.get("/api/v1/workflows/:id", auth, (req, res) => {
    const wf = state.workflows[req.params.id];
    if (!wf) return res.status(404).json({ error: "workflow not found" });
    res.json(wf);
  });

  // ── Connections / repositories (Jenkins UI dropdowns) ──
  app.get("/api/v1/services", auth, (req, res) => res.json(state.services));

  app.get("/api/v1/services/:storageId/references", auth, (req, res) => {
    res.json(state.references[req.params.storageId] || []);
  });

  // ── Scans ──
  function startScan(req, res) {
    if (state.failNextScanStart) {
      const status = state.failNextScanStart;
      state.failNextScanStart = null;
      return res.status(status).json({ error: "rejected by mock (scripted failure)" });
    }
    const id = crypto.randomUUID();
    const scenario = nextScenario();
    state.scans[id] = { scenario, pollsRemaining: scenario.pollsBeforeDone };
    res.json({ ScanIds: [id] });
  }

  app.post("/api/v1/scans", auth, startScan);
  app.post("/api/v1/scans/direct", auth, upload.single("file"), startScan);

  app.get("/api/v1/scans/:id/overview", auth, (req, res) => {
    const scan = state.scans[req.params.id];
    if (!scan) return res.status(404).json({ error: "scan not found" });
    const body = buildResultBody(scan);
    if (scan.pollsRemaining > 0) scan.pollsRemaining -= 1;
    res.json(body);
  });

  app.get("/api/v1/scans/:id", auth, (req, res) => {
    const scan = state.scans[req.params.id];
    if (!scan) return res.status(404).json({ error: "scan not found" });
    res.json(buildResultBody(scan, { forceFinal: true }));
  });

  // ── Control plane (test-only) ──
  const control = express.Router();
  control.post("/reset", (req, res) => {
    resetState();
    res.json({ ok: true });
  });
  control.post("/api-key", (req, res) => {
    state.apiKey = req.body.value;
    res.json({ ok: true });
  });
  control.post("/services", (req, res) => {
    state.services = req.body;
    res.json({ ok: true });
  });
  control.post("/references/:storageId", (req, res) => {
    state.references[req.params.storageId] = req.body;
    res.json({ ok: true });
  });
  control.post("/workflows/:id", (req, res) => {
    state.workflows[req.params.id] = req.body;
    res.json({ ok: true });
  });
  control.post("/scan-scenario", (req, res) => {
    state.scanQueue.push({ ...defaultScenario(), ...req.body });
    res.json({ ok: true });
  });
  control.post("/fail-next-scan-start", (req, res) => {
    state.failNextScanStart = Number(req.body?.status) || 400;
    res.json({ ok: true });
  });
  control.get("/scans/:id", (req, res) => {
    res.json(state.scans[req.params.id] || null);
  });
  app.use("/_control", control);

  return app;
}

function start(port = 0) {
  const app = createApp();
  return new Promise((resolve) => {
    const server = app.listen(port, "127.0.0.1", () => resolve(server));
  });
}

if (require.main === module) {
  const port = Number(process.env.PORT) || 4567;
  start(port).then((server) => {
    const addr = server.address();
    console.log(`[mock-mdssc] listening on http://127.0.0.1:${addr.port}`);
  });
}

module.exports = { createApp, start };
