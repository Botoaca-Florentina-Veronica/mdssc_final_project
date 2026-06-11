// @ts-check
const { test, expect } = require('@playwright/test');
const { MdsscClient } = require('../../helpers/api-client');

const BASE_URL = process.env.MDSSC_INSTANCE || 'http://localhost:4000';

function client(request, scenario) {
  return new MdsscClient(request, BASE_URL, { scenario });
}

test.describe('Source Code Scan Step', () => {
  test('fails with "Repository not found" when repository does not exist', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startSourceScan({ repository: 'repo-not-found', branch: 'main' });
    expect(res.status()).toBe(404);
    const body = await res.json();
    expect(body.error).toMatch(/repository not found/i);
  });

  test('fails with "Branch not found" when branch does not exist', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startSourceScan({ repository: 'test-repo', branch: 'branch-not-found' });
    expect(res.status()).toBe(404);
    const body = await res.json();
    expect(body.error).toMatch(/branch not found/i);
  });

  test('fails with descriptive error on invalid connection ID', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startSourceScan({
      repository: 'test-repo',
      branch: 'main',
      connectionId: 'invalid-connection',
    });
    expect(res.status()).toBe(400);
    const body = await res.json();
    expect(body.error).toMatch(/invalid connection/i);
  });

  test('fails with "Workflow not found" when workflow ID is invalid', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startSourceScan({
      repository: 'test-repo',
      branch: 'main',
      workflowId: 'workflow-not-found',
    });
    expect(res.status()).toBe(404);
    const body = await res.json();
    expect(body.error).toMatch(/workflow not found/i);
  });

  test('uses default workflow when workflowId is omitted', async ({ request }) => {
    const c = client(request, 'clean');
    const res = await c.startSourceScan({ repository: 'test-repo', branch: 'main' });
    // No workflowId → should succeed and start a scan
    expect(res.ok()).toBe(true);
    const body = await res.json();
    expect(body.id).toBeDefined();
  });

  test('full flow: clean source scan passes gate', async ({ request }) => {
    const c = client(request, 'clean');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'critical', failOnSecret: true, failOnMalware: true }
    );
    expect(passed).toBe(true);
  });

  test('poll overview reflects COMPLETED status after scan starts', async ({ request }) => {
    const c = client(request, 'clean');
    const startRes = await c.startSourceScan({ repository: 'test-repo', branch: 'main' });
    expect(startRes.ok()).toBe(true);
    const { id } = await startRes.json();

    const overviewRes = await c.pollOverview(id);
    expect(overviewRes.ok()).toBe(true);
    const overview = await overviewRes.json();
    expect(overview.status).toBe('COMPLETED');
  });
});
