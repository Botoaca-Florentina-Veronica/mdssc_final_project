// Spawns the real CI scripts (ci/scripts/mdssc-source-scan.sh, mdssc-artifact-scan.sh)
// exactly as the GitHub Actions pipeline does, pointed at the mock MDSSC server.
// This is the core of the E2E suite: it exercises production code, not a re-implementation
// of it.
const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const SCRIPTS_DIR = path.join(REPO_ROOT, "ci", "scripts");

function parseGithubOutput(file) {
  const out = {};
  let raw = "";
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return out;
  }
  for (const line of raw.split("\n")) {
    const idx = line.indexOf("=");
    if (idx > 0) out[line.slice(0, idx)] = line.slice(idx + 1);
  }
  return out;
}

function readJsonDir(dir) {
  const files = {};
  let names = [];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return files;
  }
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      files[name] = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
    } catch {
      files[name] = null;
    }
  }
  return files;
}

/**
 * @param {"mdssc-source-scan.sh"|"mdssc-artifact-scan.sh"} scriptName
 * @param {Record<string,string>} env  Extra/overriding environment variables.
 * @returns {Promise<{exitCode:number, stdout:string, stderr:string, outputs:object, scanResults:object, cwd:string}>}
 */
function runScript(scriptName, env = {}) {
  return new Promise((resolve) => {
    const scriptPath = path.join(SCRIPTS_DIR, scriptName);
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "mdssc-e2e-"));
    const githubOutput = path.join(cwd, "github-output.txt");
    fs.writeFileSync(githubOutput, "");

    const fullEnv = {
      ...process.env,
      GITHUB_OUTPUT: githubOutput,
      ...env,
    };

    execFile(
      "bash",
      [scriptPath],
      { cwd, env: fullEnv, maxBuffer: 16 * 1024 * 1024 },
      (error, stdout, stderr) => {
        resolve({
          exitCode: error ? (typeof error.code === "number" ? error.code : 1) : 0,
          stdout,
          stderr,
          outputs: parseGithubOutput(githubOutput),
          scanResults: readJsonDir(path.join(cwd, "scan-results")),
          cwd,
        });
      }
    );
  });
}

function cleanup(cwd) {
  try {
    fs.rmSync(cwd, { recursive: true, force: true });
  } catch {
    /* best effort */
  }
}

// Creates a throwaway directory with a single fixture file inside it, used as
// the "artifact" that mdssc-artifact-scan.sh tars and uploads.
function makeArtifactDir(sizeBytes = 1024) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mdssc-e2e-artifact-"));
  fs.writeFileSync(path.join(dir, "fixture.bin"), Buffer.alloc(sizeBytes, "A"));
  return dir;
}

module.exports = { runScript, cleanup, makeArtifactDir, REPO_ROOT };
