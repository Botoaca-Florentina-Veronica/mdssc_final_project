// Bad-input tests — README.md → "Track C — Common Tests → Bad input tests".
//
// Both CI scripts are deliberately designed to degrade gracefully instead of
// blocking the pipeline whenever MDSSC is unreachable or misconfigured (see
// the "Mock fallback" sections of mdssc-source-scan.sh / mdssc-artifact-scan.sh).
// These tests pin down that graceful-degradation contract: connectivity and
// credential problems must never produce a hard pipeline failure, while
// missing local prerequisites (e.g. no build artifact) still must.
const { test, expect } = require("@playwright/test");
const mock = require("../../utils/mock-control");
const { runScript, cleanup, makeArtifactDir } = require("../../utils/run-script");

test.describe("Common — bad input (source scan, graceful mock fallback)", () => {
  test.beforeEach(async () => {
    await mock.reset();
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
  });

  function assertGracefulFallback(result) {
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).toBe("mock-src-fallback");
    expect(result.scanResults["source-scan.json"]?.mock).toBe(true);
  }

  test("missing MDSSC_INSTANCE/MDSSC_API_KEY", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: "",
      MDSSC_API_KEY: "",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("unreachable MDSSC URL", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: "http://127.0.0.1:1",
      MDSSC_API_KEY: "mock-api-key",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("malformed MDSSC instance URL", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: "not-a-url",
      MDSSC_API_KEY: "mock-api-key",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("invalid API key — no workflow id preset", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "WRONG-KEY",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("invalid API key — workflow id preset", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "WRONG-KEY",
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("workflow id not found", async () => {
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "mock-api-key",
      MDSSC_WORKFLOW_ID: "does-not-exist",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });

  test("invalid connection id → 400", async () => {
    await mock.failNextScanStart(400);
    const result = await runScript("mdssc-source-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "mock-api-key",
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    assertGracefulFallback(result);
    cleanup(result.cwd);
  });
});

test.describe("Common — bad input (artifact scan, graceful mock fallback)", () => {
  let artifactDir;

  test.beforeEach(async () => {
    await mock.reset();
    artifactDir = makeArtifactDir();
  });

  test.afterEach(() => cleanup(artifactDir));

  function assertGracefulFallback(result) {
    expect(result.exitCode).toBe(0);
    expect(result.outputs.passed).toBe("true");
    expect(result.outputs["scan-id"]).toBe("mock-art-fallback");
    const file = Object.values(result.scanResults)[0];
    expect(file?.mock).toBe(true);
  }

  test("missing MDSSC_INSTANCE/MDSSC_API_KEY", async () => {
    const result = await runScript("mdssc-artifact-scan.sh", {
      MDSSC_INSTANCE: "",
      MDSSC_API_KEY: "",
      MDSSC_ARTIFACT_DIR: artifactDir,
    });
    assertGracefulFallback(result);
  });

  test("unreachable MDSSC URL", async () => {
    const result = await runScript("mdssc-artifact-scan.sh", {
      MDSSC_INSTANCE: "http://127.0.0.1:1",
      MDSSC_API_KEY: "mock-api-key",
      MDSSC_ARTIFACT_DIR: artifactDir,
    });
    assertGracefulFallback(result);
  });

  test("invalid API key", async () => {
    const result = await runScript("mdssc-artifact-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "WRONG-KEY",
      MDSSC_ARTIFACT_DIR: artifactDir,
    });
    assertGracefulFallback(result);
  });

  test("missing required field — artifact directory does not exist → hard failure", async () => {
    // Unlike connectivity/credential issues, a missing local build artifact is a
    // real pipeline defect (the build stage didn't run) and must fail the build.
    const result = await runScript("mdssc-artifact-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "mock-api-key",
      MDSSC_ARTIFACT_DIR: "/tmp/this-directory-does-not-exist-e2e",
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.outputs.passed).toBeUndefined();
  });

  test("invalid connection id → 400", async () => {
    await mock.setWorkflow("wf-1", { storageId: "storage-1", repositoryId: "repo-1" });
    await mock.failNextScanStart(400);
    const result = await runScript("mdssc-artifact-scan.sh", {
      MDSSC_INSTANCE: mock.BASE_URL,
      MDSSC_API_KEY: "mock-api-key",
      MDSSC_ARTIFACT_DIR: artifactDir,
      MDSSC_WORKFLOW_ID: "wf-1",
    });
    assertGracefulFallback(result);
  });
});
