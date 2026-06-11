// @ts-check
const { test, expect } = require('@playwright/test');
const { MdsscClient } = require('../../helpers/api-client');

const BASE_URL = process.env.MDSSC_INSTANCE || 'http://localhost:4000';

function client(request, scenario) {
  return new MdsscClient(request, BASE_URL, { scenario });
}

test.describe('Secrets Detection', () => {
  test('build fails when secrets detected and failOnSecret is enabled', async ({ request }) => {
    const c = client(request, 'has-secret');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'none', failOnSecret: true, failOnMalware: false }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('secret');
  });

  test('build passes when secrets detected but failOnSecret is disabled', async ({ request }) => {
    const c = client(request, 'has-secret');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startSourceScan({ repository: 'test-repo', branch: 'main' }),
      { vulnerabilityThreshold: 'none', failOnSecret: false, failOnMalware: false }
    );
    expect(passed).toBe(true);
  });

  test('artifact scan fails when secrets detected and failOnSecret is enabled', async ({ request }) => {
    const c = client(request, 'has-secret');
    const { passed, reason } = await c.runScanAndEvaluate(
      () => c.startArtifactScan({}),
      { vulnerabilityThreshold: 'none', failOnSecret: true, failOnMalware: false }
    );
    expect(passed).toBe(false);
    expect(reason).toContain('secret');
  });

  test('artifact scan passes when secrets detected but failOnSecret is disabled', async ({ request }) => {
    const c = client(request, 'has-secret');
    const { passed } = await c.runScanAndEvaluate(
      () => c.startArtifactScan({}),
      { vulnerabilityThreshold: 'none', failOnSecret: false, failOnMalware: false }
    );
    expect(passed).toBe(true);
  });
});
