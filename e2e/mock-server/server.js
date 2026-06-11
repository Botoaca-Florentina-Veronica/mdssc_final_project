'use strict';

const express = require('express');
const { SCANS } = require('./responses');

const PORT = parseInt(process.env.MOCK_PORT || '4000', 10);

function createApp() {
  const app = express();
  app.use(express.json());

  // ── Health check ────────────────────────────────────────────────────────────
  app.get('/api/v1/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  // ── Source scan ─────────────────────────────────────────────────────────────
  app.post('/api/v1/scans', (req, res) => {
    const { repository, branch, connectionId, workflowId } = req.body || {};

    if (workflowId === 'workflow-not-found') {
      return res.status(404).json({ error: 'Workflow not found' });
    }
    if (connectionId === 'invalid-connection') {
      return res.status(400).json({ error: 'Invalid connection ID' });
    }
    if (repository === 'repo-not-found') {
      return res.status(404).json({ error: 'Repository not found' });
    }
    if (branch === 'branch-not-found') {
      return res.status(404).json({ error: 'Branch not found' });
    }

    // Derive scenario from a special header or default to 'clean'
    const scenario = req.headers['x-mock-scenario'] || 'clean';
    const scanId = scenario in SCANS ? scenario : 'clean';
    res.status(201).json({ id: scanId, status: 'IN_PROGRESS' });
  });

  // ── Artifact scan (direct upload) ───────────────────────────────────────────
  app.post('/api/v1/scans/direct', (req, res) => {
    const scenario = req.headers['x-mock-scenario'] || 'clean';

    if (scenario === 'file-not-found') {
      return res.status(400).json({ error: 'File not found' });
    }
    if (scenario === 'file-too-large') {
      return res.status(413).json({ error: 'File too large' });
    }
    if (scenario === 'unsupported-type') {
      return res.status(415).json({ error: 'Unsupported file type' });
    }
    if (req.headers['x-mock-workflow'] === 'workflow-not-found') {
      return res.status(404).json({ error: 'Workflow not found' });
    }

    const scanId = scenario in SCANS ? scenario : 'clean';
    res.status(201).json({ id: scanId, status: 'IN_PROGRESS' });
  });

  // ── Scan overview (poll) ────────────────────────────────────────────────────
  app.get('/api/v1/scans/:id/overview', (req, res) => {
    const scan = SCANS[req.params.id];
    if (!scan) return res.status(404).json({ error: 'Scan not found' });
    res.json({ id: req.params.id, status: scan.status });
  });

  // ── Full scan result ────────────────────────────────────────────────────────
  app.get('/api/v1/scans/:id', (req, res) => {
    const scan = SCANS[req.params.id];
    if (!scan) return res.status(404).json({ error: 'Scan not found' });
    res.json(scan);
  });

  // ── Workflow metadata ───────────────────────────────────────────────────────
  app.get('/api/v1/workflows/:workflowId', (req, res) => {
    if (req.params.workflowId === 'workflow-not-found') {
      return res.status(404).json({ error: 'Workflow not found' });
    }
    res.json({ id: req.params.workflowId, name: 'Default Workflow' });
  });

  return app;
}

function startServer() {
  return new Promise((resolve, reject) => {
    const app = createApp();
    const server = app.listen(PORT, (err) => {
      if (err) return reject(err);
      console.log(`[mock-server] listening on http://localhost:${PORT}`);
      resolve(server);
    });
  });
}

module.exports = { createApp, startServer, PORT };

if (require.main === module) {
  startServer().catch(console.error);
}
