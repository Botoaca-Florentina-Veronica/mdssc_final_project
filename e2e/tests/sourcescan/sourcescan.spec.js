// Source Code Scan step tests — README.md → "Track C — Source Code Scan Step Tests".
const { test, expect } = require("@playwright/test");
const mock = require("../../utils/mock-control");
const { runScript, cleanup } = require("../../utils/run-script");

const baseEnv = {
  MDSSC_API_KEY: "mock-api-key",
  VULNERABILITY_THRESHOLD: "none",
  FAIL_ON_SECRET: "false",
  FAIL_ON_MALWARE: "false",
  MDSSC_SCAN_TIMEOUT: "20",
  MDSSC_POLL_INTERVAL: "1",
};

test.describe("Source Code Scan step", () => {
  test.beforeEach(async () => {
    await mock.reset();
  });

  test("repository not found on the workflow → graceful mock fallback", async () => {
    // Workflow exists but has no repositories attached — RepositoryId can't be resolved.
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "" });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs["scan-id"]).toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("invalid connection id → MDSSC rejects scan start (400) → graceful mock fallback", async () => {
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.failNextScanStart(400);
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs["scan-id"]).toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("branch not found → MDSSC rejects scan start (404) → graceful mock fallback", async () => {
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.failNextScanStart(404);
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "wf-1",
      MDSSC_BRANCH: "branch-that-does-not-exist",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs["scan-id"]).toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("workflow id not found → graceful mock fallback", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "does-not-exist",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs["scan-id"]).toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("default workflow auto-detected when Workflow ID is omitted", async () => {
    await mock.setWorkflow("wf-auto", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.scriptScan({ pollsBeforeDone: 0 });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "",
    });
    // A real scan ran (not the mock fallback) — proves auto-detection worked.
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).not.toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("full clean scan flow passes", async () => {
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.scriptScan({ pollsBeforeDone: 1 });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "wf-1",
      VULNERABILITY_THRESHOLD: "critical",
      FAIL_ON_SECRET: "true",
      FAIL_ON_MALWARE: "true",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).not.toBe("mock-src-fallback");
    cleanup(result.cwd);
  });

  test("scan reaching a Failed state aborts the build", async () => {
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.scriptScan({ finalState: "Failed", pollsBeforeDone: 0 });
    const result = await runScript("mdssc-source-scan.sh", {
      ...baseEnv,
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    expect(result.exitCode).not.toBe(0);
    cleanup(result.cwd);
  });
});
