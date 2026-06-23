// Vulnerability threshold tests — run against both real CI scripts
// (ci/scripts/mdssc-source-scan.sh and mdssc-artifact-scan.sh) pointed at the
// mock MDSSC server. See README.md → "Track C — E2E Tests → Common Tests".
const { test, expect } = require("@playwright/test");
const mock = require("../../utils/mock-control");
const { runScript, cleanup, makeArtifactDir } = require("../../utils/run-script");

test.describe("Common — vulnerability threshold (source scan)", () => {
  test.beforeEach(async () => {
    await mock.reset();
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
  });

  const baseEnv = {
    MDSSC_INSTANCE: mock.BASE_URL,
    MDSSC_API_KEY: "mock-api-key",
    MDSSC_WORKFLOW_ID: "wf-1",
    FAIL_ON_SECRET: "false",
    FAIL_ON_MALWARE: "false",
    MDSSC_SCAN_TIMEOUT: "20",
    MDSSC_POLL_INTERVAL: "1",
  };

  const failingCases = [
    { threshold: "critical", scenario: { critical: 1 }, label: "critical vuln at critical threshold" },
    { threshold: "high", scenario: { high: 1 }, label: "high vuln at high threshold" },
    { threshold: "high", scenario: { critical: 1 }, label: "critical vuln still fails high threshold" },
    { threshold: "medium", scenario: { medium: 1 }, label: "medium vuln at medium threshold" },
    { threshold: "low", scenario: { low: 1 }, label: "low vuln at low threshold" },
    { threshold: "unknown", scenario: { unknown: 1 }, label: "unknown-severity vuln at unknown threshold" },
  ];

  for (const { threshold, scenario, label } of failingCases) {
    test(`build fails — ${label}`, async () => {
      await mock.scriptScan({ ...scenario, pollsBeforeDone: 1 });
      const result = await runScript("mdssc-source-scan.sh", {
        ...baseEnv,
        VULNERABILITY_THRESHOLD: threshold,
      });
      expect(result.exitCode).not.toBe(0);
      expect(result.outputs.passed).toBeUndefined();
      cleanup(result.cwd);
    });
  }

  test("build succeeds — threshold none ignores any vulnerability count", async () => {
    await mock.scriptScan({ critical: 5, high: 5, medium: 5, low: 5, pollsBeforeDone: 0 });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      VULNERABILITY_THRESHOLD: "none",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    cleanup(result.cwd);
  });

  test("build succeeds — critical threshold ignores high-only findings", async () => {
    await mock.scriptScan({ high: 5, pollsBeforeDone: 0 });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      VULNERABILITY_THRESHOLD: "critical",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    cleanup(result.cwd);
  });
});

test.describe("Common — vulnerability threshold (artifact scan)", () => {
  let artifactDir;

  test.beforeEach(async () => {
    await mock.reset();
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    artifactDir = makeArtifactDir();
  });

  test.afterEach(() => cleanup(artifactDir));

  const baseEnv = () => ({
    MDSSC_INSTANCE: mock.BASE_URL,
    MDSSC_API_KEY: "mock-api-key",
    MDSSC_WORKFLOW_ID: "wf-1",
    MDSSC_ARTIFACT_DIR: artifactDir,
    FAIL_ON_SECRET: "false",
    FAIL_ON_MALWARE: "false",
    MDSSC_SCAN_TIMEOUT: "20",
    MDSSC_POLL_INTERVAL: "1",
  });

  const failingCases = [
    { threshold: "critical", scenario: { critical: 1 } },
    { threshold: "high", scenario: { high: 1 } },
    { threshold: "medium", scenario: { medium: 1 } },
    { threshold: "low", scenario: { low: 1 } },
    { threshold: "unknown", scenario: { unknown: 1 } },
  ];

  for (const { threshold, scenario } of failingCases) {
    test(`build fails — ${threshold} threshold exceeded`, async () => {
      await mock.scriptScan({ ...scenario, pollsBeforeDone: 1 });
      const result = await runScript("mdssc-artifact-scan.sh", {
        ...baseEnv(),
        VULNERABILITY_THRESHOLD: threshold,
      });
      expect(result.exitCode).not.toBe(0);
      expect(result.outputs.passed).toBe("false");
    });
  }

  test("build succeeds — threshold none ignores any vulnerability count", async () => {
    await mock.scriptScan({ critical: 5, pollsBeforeDone: 0 });
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(),
      VULNERABILITY_THRESHOLD: "none",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
  });
});
