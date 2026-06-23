// @ts-check
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests",
  // Tests share one mock-server process and its in-memory state (scripted via
  // /_control), so they must not run concurrently against it.
  workers: 1,
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  timeout: 60_000,
  reporter: process.env.CI
    ? [["list"], ["html", { open: "never" }], ["json", { outputFile: "test-results/e2e-results.json" }]]
    : "list",
  globalSetup: require.resolve("./global-setup.js"),
  globalTeardown: require.resolve("./global-teardown.js"),
});
