'use strict';

const { startServer } = require('./server');

module.exports = async function globalSetup() {
  // Skip mock server when running against a real MDSSC instance
  if (process.env.MDSSC_INSTANCE) {
    console.log('[global-setup] MDSSC_INSTANCE set — skipping mock server');
    return;
  }
  const server = await startServer();
  // Store handle so teardown can close it
  globalThis.__mockServer = server;
};
