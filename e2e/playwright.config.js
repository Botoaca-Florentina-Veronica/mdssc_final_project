// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 30_000,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 4 : undefined,

  reporter: [
    ['list'],
    ['html',  { outputFolder: 'playwright-report', open: 'never' }],
    ['json',  { outputFile: 'test-results/results.json' }],
    ['junit', { outputFile: 'test-results/junit.xml' }],
  ],

  use: {
    // API tests only — no browser needed except for coverage report
    baseURL: process.env.MOCK_SERVER_URL || 'http://localhost:4000',
    extraHTTPHeaders: {
      'x-api-key': process.env.MDSSC_API_KEY || 'test-api-key',
    },
  },

  // Spin up the mock MDSSC server before all tests
  globalSetup:    require.resolve('./mock-server/global-setup.js'),
  globalTeardown: require.resolve('./mock-server/global-teardown.js'),

  projects: [
    {
      name: 'API Tests',
      use: {},
    },
  ],
});
