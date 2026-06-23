// Artifact Scan step tests — README.md → "Track C — Artifact Scan Step Tests".
const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");
const mock = require("../../utils/mock-control");
const { runScript, cleanup, makeArtifactDir } = require("../../utils/run-script");

const baseEnv = (artifactDir) => ({
  MDSSC_INSTANCE: mock.BASE_URL,
  MDSSC_API_KEY: "mock-api-key",
  MDSSC_ARTIFACT_DIR: artifactDir,
  VULNERABILITY_THRESHOLD: "none",
  FAIL_ON_SECRET: "false",
  FAIL_ON_MALWARE: "false",
  MDSSC_SCAN_TIMEOUT: "20",
  MDSSC_POLL_INTERVAL: "1",
});

test.describe("Artifact Scan step", () => {
  let artifactDir;

  test.beforeEach(async () => {
    await mock.reset();
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    artifactDir = makeArtifactDir();
  });

  test.afterEach(() => cleanup(artifactDir));

  test("file (artifact directory) not found → hard failure", async () => {
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_ARTIFACT_DIR: path.join(artifactDir, "does-not-exist"),
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.outputs.passed).toBeUndefined();
  });

  test("artifact exceeds MDSSC_MAX_UPLOAD_MB — skipped, build still passes", async () => {
    // Random bytes so the tar.gz archive can't be compressed away below the limit.
    fs.writeFileSync(path.join(artifactDir, "big.bin"), require("crypto").randomBytes(2 * 1024 * 1024));
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "wf-1",
      MDSSC_MAX_UPLOAD_MB: "1",
      MDSSC_SKIP_LARGE_ARTIFACTS: "true",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).toBe("skipped-too-large");
  });

  test("artifact exceeds MDSSC_MAX_UPLOAD_MB with skip disabled — hard failure", async () => {
    fs.writeFileSync(path.join(artifactDir, "big.bin"), require("crypto").randomBytes(2 * 1024 * 1024));
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "wf-1",
      MDSSC_MAX_UPLOAD_MB: "1",
      MDSSC_SKIP_LARGE_ARTIFACTS: "false",
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.outputs.passed).toBe("false");
  });

  test("unsupported file type rejected by MDSSC (415) → graceful mock fallback", async () => {
    await mock.failNextScanStart(415);
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).toBe("mock-art-fallback");
  });

  test("full clean scan flow passes", async () => {
    await mock.scriptScan({ pollsBeforeDone: 1 });
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "wf-1",
      VULNERABILITY_THRESHOLD: "critical",
      FAIL_ON_SECRET: "true",
      FAIL_ON_MALWARE: "true",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).not.toBe("mock-art-fallback");
  });

  test("workflow id not found — workflow field omitted from the upload, scan still proceeds", async () => {
    await mock.scriptScan({ pollsBeforeDone: 0 });
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "does-not-exist",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).not.toBe("mock-art-fallback");
  });

  test("default workflow auto-detected when Workflow ID is omitted", async () => {
    await mock.scriptScan({ pollsBeforeDone: 0 });
    const result = await runScript("mdssc-artifact-scan.sh", {
      ...baseEnv(artifactDir),
      MDSSC_WORKFLOW_ID: "",
    });
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).not.toBe("mock-art-fallback");
  });
});
