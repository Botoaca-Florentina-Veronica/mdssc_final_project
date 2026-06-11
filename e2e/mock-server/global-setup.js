'use strict';

const { startServer } = require('./server');

module.exports = async function globalSetup() {
  // Always start the mock server — E2E tests always run against it.
  // MDSSC_INSTANCE is used only by the scan shell scripts, not by tests.
  const server = await startServer();
  globalThis.__mockServer = server;
};
