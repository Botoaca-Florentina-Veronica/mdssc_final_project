// @ts-check
const { test, expect } = require('@playwright/test');
const { MdsscClient } = require('../../helpers/api-client');

const BASE_URL = process.env.MDSSC_INSTANCE || 'http://localhost:4000';

// Helper: create a client for a given mock scenario
function client(request, scenario) {
  return new MdsscClient(request, BASE_URL, { scenario });
}

test.describe('Vulnerability Threshold — Source Code Scan', () => {
  test('fails when scan has critical vulnerabilities and threshold is critical', async ({ request }) => {
    const c = client(request, 'has-critical');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'critical' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('critical');
  });

  test('fails when scan has high vulnerabilities and threshold is high', async ({ request }) => {
    const c = client(request, 'has-high');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'high' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('high');
  });

  test('fails when scan has medium vulnerabilities and threshold is medium', async ({ request }) => {
    const c = client(request, 'has-medium');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'medium' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('medium');
  });

  test('fails when scan has low vulnerabilities and threshold is low', async ({ request }) => {
    const c = client(request, 'has-low');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'low' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('low');
  });

  test('fails when scan has unknown severity and threshold is unknown', async ({ request }) => {
    const c = client(request, 'has-unknown');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'unknown' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('unknown');
  });

  test('passes when threshold is none regardless of findings', async ({ request }) => {
    const c = client(request, 'has-critical');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'none' }
    );
    expect(passed).toBe(true);
  });

  test('passes when scan is clean with default threshold', async ({ request }) => {
    const c = client(request, 'clean');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'critical' }
    );
    expect(passed).toBe(true);
  });
});

test.describe('Vulnerability Threshold — Artifact Scan', () => {
  test('fails when artifact scan has critical vulnerabilities', async ({ request }) => {
    const c = client(request, 'has-critical');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startArtifactScan({}),
      { vulnerabilityThreshold: 'critical' }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('critical');
  });

  test('passes when threshold is none regardless of artifact findings', async ({ request }) => {
    const c = client(request, 'has-critical');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startArtifactScan({}),
      { vulnerabilityThreshold: 'none' }
    );
    expect(passed).toBe(true);
  });
});
