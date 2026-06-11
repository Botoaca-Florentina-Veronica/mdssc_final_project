'use strict';

const SEVERITY_ORDER = ['none', 'unknown', 'low', 'medium', 'high', 'critical'];

/**
 * Thin wrapper around the MDSSC REST API.
 * Used by E2E tests to invoke scan logic identical to the Jenkins plugin.
 */
class MdsscClient {
  /**
   * @param {import('@playwright/test').APIRequestContext} request  Playwright request context
   * @param {string} baseUrl   MDSSC instance URL
   * @param {object} [opts]
   * @param {string} [opts.scenario]  x-mock-scenario header (mock server only)
   */
  constructor(request, baseUrl, opts = {}) {
    this._req      = request;
    this._baseUrl  = baseUrl.replace(/\/$/, '');
    this._scenario = opts.scenario || 'clean';
  }

  // ── Health ──────────────────────────────────────────────────────────────────
  async health() {
    const res = await this._req.get(`${this._baseUrl}/api/v1/health`);
    return res;
  }

  // ── Source scan ─────────────────────────────────────────────────────────────
  async startSourceScan(params = {}) {
    return this._req.post(`${this._baseUrl}/api/v1/scans`, {
      headers: { 'x-mock-scenario': this._scenario },
      data: params,
    });
  }

  // ── Artifact scan ────────────────────────────────────────────────────────────
  async startArtifactScan(params = {}) {
    const headers = { 'x-mock-scenario': this._scenario };
    if (params.workflowId === 'workflow-not-found') {
      headers['x-mock-workflow'] = 'workflow-not-found';
    }
    return this._req.post(`${this._baseUrl}/api/v1/scans/direct`, {
      headers,
      data: params,
    });
  }

  // ── Poll overview ────────────────────────────────────────────────────────────
  async pollOverview(scanId) {
    return this._req.get(`${this._baseUrl}/api/v1/scans/${scanId}/overview`);
  }

  // ── Full result ──────────────────────────────────────────────────────────────
  async getResult(scanId) {
    return this._req.get(`${this._baseUrl}/api/v1/scans/${scanId}`);
  }

  // ── Workflow metadata ─────────────────────────────────────────────────────────
  async getWorkflow(workflowId) {
    return this._req.get(`${this._baseUrl}/api/v1/workflows/${workflowId}`);
  }

  // ── Higher-level helper: run a full scan and evaluate gate ───────────────────
  async runScanAndEvaluate(startFn, gateOpts = {}) {
    const {
      vulnerabilityThreshold = 'critical',
      failOnSecret  = true,
      failOnMalware = true,
    } = gateOpts;

    const startRes = await startFn();
    if (!startRes.ok()) {
      const body = await startRes.json();
      return { passed: false, httpStatus: startRes.status(), error: body.error || 'Scan start failed' };
    }

    const { id: scanId } = await startRes.json();

    // Single poll is enough for the mock server; real polling happens in the shell scripts
    const overviewRes = await this.pollOverview(scanId);
    if (!overviewRes.ok()) {
      return { passed: false, httpStatus: overviewRes.status(), error: 'Poll failed' };
    }

    const resultRes = await this.getResult(scanId);
    if (!resultRes.ok()) {
      return { passed: false, httpStatus: resultRes.status(), error: 'Result fetch failed' };
    }

    const result = await resultRes.json();
    const { summary = {}, secrets = 0, malware = 0 } = result;

    const thresholdIdx = SEVERITY_ORDER.indexOf(vulnerabilityThreshold);
    let failed = false;
    let failReason = '';

    for (let i = thresholdIdx; i < SEVERITY_ORDER.length; i++) {
      const sev = SEVERITY_ORDER[i];
      if (sev !== 'none' && (summary[sev] || 0) > 0) {
        failed = true;
        failReason = `${sev} vulnerabilities found`;
        break;
      }
    }
    if (!failed && failOnSecret  && secrets  > 0) { failed = true; failReason = 'secrets detected'; }
    if (!failed && failOnMalware && malware  > 0) { failed = true; failReason = 'malware detected'; }

    return { passed: !failed, reason: failReason, result };
  }
}

module.exports = { MdsscClient };
