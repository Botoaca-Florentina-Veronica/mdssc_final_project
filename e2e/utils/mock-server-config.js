// Shared constants between global-setup.js (spawns the mock server) and
// mock-control.js (talks to it from the tests).
const PORT = Number(process.env.MOCK_MDSSC_PORT) || 4567;
const BASE_URL = `http://127.0.0.1:${PORT}`;

module.exports = { PORT, BASE_URL };
