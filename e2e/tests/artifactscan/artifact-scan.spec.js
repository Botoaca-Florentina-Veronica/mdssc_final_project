// @ts-check
const { test, expect } = require('@playwright/test');
const { MdsscClient } = require('../../helpers/api-client');

const BASE_URL = process.env.MDSSC_INSTANCE || 'http://localhost:4000';

function client(request, scenario) {
  return new MdsscClient(request, BASE_URL, { scenario });
}

test.describe('Artifact Scan Step', () => {
  test('fails with "File not found" when artifact path is missing', async ({ request }) => {
    const c = client(request, 'file-not-found');
    const res = await c.startArtifactScan({});
    expect(res.status()).toBe(400);
    const body = await res.json();
    expect(body.error).toMatch(/file not found/i);
  });

  test('fails with "File too large" when artifact exceeds size limit', async ({ request }) => {
    const c = client(request, 'file-too-large');
    const res = await c.startArtifactScan({});
    expect(res.status()).toBe(413);
    const body = await res.json();
    expect(body.error).toMatch(/file too large/i);
  });

  test('fails with appropriate error for unsupported file type', async ({ request }) => {
    const c = client(request, 'unsupported-type');
    const res = await c.startArtifactScan({});
    expect(res.status()).toBe(415);
    const body = await res.json();
    expect(body.error).toBeTruthy();
  });

  test('fails with "Workflow not found" when workflow ID is invalid', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startArtifactScan({ workflowId: 'workflow-not-found' });
    expect(res.status()).toBe(404);
    const body = await res.json();
    expect(body.error).toMatch(/workflow not found/i);
  });

  test('uses default workflow when workflowId is omitted', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startArtifactScan({});
    expect(res.ok()).toBe(true);
    const body = await res.json();
    expect(body.id).toBeDefined();
  });

  test('full flow: clean artifact scan passes gate', async ({ request }) => {
    const c = client(request, 'clean');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startArtifactScan({}),
      { vulnerabilityThreshold: 'critical', failOnSecret: true, failOnMalware: true }
    );
    expect(passed).toBe(true);
  });

  test('poll overview reflects COMPLETED status after artifact scan starts', async ({ request }) => {
    const c = client(request, 'clean');
    const startRes = await c.startArtifactScan({});
    expect(startRes.ok()).toBe(true);
    const { id } = await startRes.json();

    const overviewRes = await c.pollOverview(id);
    expect(overviewRes.ok()).toBe(true);
    const overview = await overviewRes.json();
    expect(overview.status).toBe('COMPLETED');
  });

  test('full result contains summary breakdown', async ({ request }) => {
    const c = client(request, 'has-critical');
    const startRes = await c.startArtifactScan({});
    const { id } = await startRes.json();
    const resultRes = await c.getResult(id);
    const result = await resultRes.json();
    expect(result.summary).toBeDefined();
    expect(typeof result.summary.critical).toBe('number');
  });
});
