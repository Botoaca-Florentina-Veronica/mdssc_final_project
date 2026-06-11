'use strict';

module.exports = async function globalTeardown() {
  if (globalThis.__mockServer) {
    await new Promise(resolve => globalThis.__mockServer.close(resolve));
    console.log('[global-teardown] mock server stopped');
  }
};
