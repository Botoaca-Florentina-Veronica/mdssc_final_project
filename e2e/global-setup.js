const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { PORT, BASE_URL } = require("./utils/mock-server-config");

const RUNTIME_FILE = path.join(__dirname, ".mock-server-runtime.json");

module.exports = async function globalSetup() {
  const serverPath = path.join(__dirname, "mock-server", "server.js");
  const child = spawn(process.execPath, [serverPath], {
    env: { ...process.env, PORT: String(PORT) },
    stdio: "ignore",
  });
  fs.writeFileSync(RUNTIME_FILE, JSON.stringify({ pid: child.pid }));
  child.unref();

  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE_URL}/version`);
      if (res.ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Mock MDSSC server did not respond at ${BASE_URL} within 15s`);
};
