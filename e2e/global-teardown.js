const fs = require("fs");
const path = require("path");

const RUNTIME_FILE = path.join(__dirname, ".mock-server-runtime.json");

module.exports = async function globalTeardown() {
  try {
    const { pid } = JSON.parse(fs.readFileSync(RUNTIME_FILE, "utf8"));
    process.kill(pid);
  } catch {
    /* already gone */
  }
  try {
    fs.unlinkSync(RUNTIME_FILE);
  } catch {
    /* nothing to clean up */
  }
};
