#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');

const ARTIFACTS = 'artifacts';
const OUT_DIR   = 'test-results';

fs.mkdirSync(OUT_DIR, { recursive: true });

function readJson(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, 'utf8')); }
  catch { return null; }
}

function stageEmoji(status) {
  return { success: '✅', failure: '❌', skipped: '⏭️', cancelled: '🚫' }[status] ?? '⚠️';
}

const stages = {
  sourceCodeScan: {
    label: 'Source Code Scan',
    status: process.env.SOURCE_SCAN_STATUS || 'skipped',
    result: readJson(path.join(ARTIFACTS, 'source-scan-results', 'source-scan.json')),
  },
  securityScan: {
    label: 'Security Scan',
    status: process.env.SECURITY_SCAN_STATUS || 'skipped',
    result: readJson(path.join(ARTIFACTS, 'security-audit', 'e2e-audit.json')),
  },
  build: {
    label: 'Build Plugin (.hpi)',
    status: process.env.BUILD_STATUS || 'skipped',
    result: null,
  },
  artifactScan: {
    label: 'Artifact Scan',
    status: process.env.ARTIFACT_SCAN_STATUS || 'skipped',
    result: readJson(path.join(ARTIFACTS, 'artifact-scan-results', 'artifact-scan.json')),
  },
  pluginTest: {
    label: 'Plugin Integration Test',
    status: process.env.PLUGIN_TEST_STATUS || 'skipped',
    result: null,
  },
  e2eTests: {
    label: 'E2E Tests',
    status: process.env.E2E_STATUS || 'skipped',
    result: null,
  },
  release: {
    label: 'Release Plugin (.hpi)',
    status: process.env.RELEASE_STATUS || 'skipped',
    result: null,
  },
};

// Load E2E JSON results if present
const e2eDir = path.join(ARTIFACTS, 'e2e-test-results');
if (fs.existsSync(e2eDir)) {
  const jsonFiles = fs.readdirSync(e2eDir).filter(f => f.endsWith('.json'));
  if (jsonFiles.length > 0) {
    stages.e2eTests.result = jsonFiles
      .map(f => readJson(path.join(e2eDir, f)))
      .filter(Boolean);
  }
}

// Mărimea artefactului .hpi (descărcat de jobul report în artifacts/)
function fileSize(p) {
  try { return fs.statSync(p).size; } catch { return null; }
}
const hpiBytes = fileSize(path.join(ARTIFACTS, 'mdssc-plugin-hpi', 'mdssc-plugin.hpi'));
if (hpiBytes != null) {
  stages.build.result = { ...(stages.build.result || {}), sizeBytes: hpiBytes };
}

// Normalizează rezultatul MDSSC într-o formă constantă pentru frontend.
// Răspunsul real ține vulnerabilitățile în ScanInformation.VulnerabilityIssues
// (sau VulnerabilityIssues), iar mock-ul în summary — le unificăm aici.
function normalizeScan(raw) {
  if (!raw || typeof raw !== 'object') return raw;
  const c = (raw.ScanInformation && raw.ScanInformation.VulnerabilityIssues)
    || raw.VulnerabilityIssues || raw.vulnerabilityIssues || raw.summary || {};
  const sev = (...keys) => {
    for (const k of keys) if (c[k] != null) return Number(c[k]) || 0;
    return 0;
  };
  const si = raw.ScanInformation || {};
  const malware = si.Malware === true ? 1 : (Number(si.InfectedFiles  ?? raw.malware ?? 0) || 0);
  const secrets = si.Secret  === true ? 1 : (Number(si.FilesWithSecrets ?? raw.secrets ?? 0) || 0);
  return {
    mock: raw.mock === true,
    ScanId: raw.ScanId || raw.id || raw.Id || null,
    summary: {
      critical: sev('critical', 'Critical'),
      high:     sev('high', 'High'),
      medium:   sev('medium', 'Medium'),
      low:      sev('low', 'Low'),
      unknown:  sev('unknown', 'Unknown'),
    },
    secrets,
    malware,
  };
}
stages.sourceCodeScan.result = normalizeScan(stages.sourceCodeScan.result);
stages.artifactScan.result   = normalizeScan(stages.artifactScan.result);

// Durata fiecărui stage — din GitHub Actions jobs API (jobul report rulează ultimul)
async function attachDurations() {
  const token = process.env.GITHUB_TOKEN;
  const runId = process.env.RUN_ID;
  const repo  = process.env.REPO;
  if (!token || !runId || !repo) return;

  // Numărul din numele jobului ("1 · Source Code Scan") → cheia stage-ului
  const byNum = {
    1: 'sourceCodeScan', 2: 'securityScan', 3: 'build',
    4: 'artifactScan', 5: 'pluginTest', 6: 'e2eTests',
  };
  try {
    const res = await fetch(
      `https://api.github.com/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`,
      { headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'mdssc-report',
      } }
    );
    if (!res.ok) { console.log(`  (durate: jobs API ${res.status})`); return; }
    const data = await res.json();
    for (const job of data.jobs || []) {
      const m = /^\s*(\d+)/.exec(job.name || '');
      let key = m && byNum[Number(m[1])];
      if (!key && /release/i.test(job.name || '')) key = 'release';
      if (!key || !stages[key] || !job.started_at || !job.completed_at) continue;
      const secs = Math.round((new Date(job.completed_at) - new Date(job.started_at)) / 1000);
      if (secs >= 0) stages[key].durationSeconds = secs;
    }
  } catch (e) {
    console.log(`  (durate indisponibile: ${e.message})`);
  }
}

async function main() {
  await attachDurations();

  const overallStatus = Object.values(stages).every(s =>
    ['success', 'skipped'].includes(s.status)
  ) ? 'success' : 'failure';

  // Extrage scan ID-urile din rezultatele MDSSC (câmpul ScanId sau id)
  const sourceScanId   = stages.sourceCodeScan.result?.ScanId || stages.sourceCodeScan.result?.id || null;
  const artifactScanId = stages.artifactScan.result?.ScanId   || stages.artifactScan.result?.id   || null;
  const mdsscInstance     = (process.env.MDSSC_INSTANCE || '').replace(/\/$/, '');
  const mdsscRepositoryId = process.env.MDSSC_REPOSITORY_ID || '';

  const report = {
    generatedAt:   new Date().toISOString(),
    overallStatus,
    commit:  process.env.COMMIT_SHA || 'unknown',
    branch:  process.env.BRANCH     || 'unknown',
    repo:    process.env.REPO       || 'unknown',
    runUrl:  process.env.RUN_URL    || '#',
    mdsscInstance,
    mdsscRepositoryId,
    sourceScanId,
    artifactScanId,
    stages,
  };

  fs.writeFileSync(
    path.join(OUT_DIR, 'pipeline-report.json'),
    JSON.stringify(report, null, 2)
  );

  console.log(`\nPipeline Report — ${overallStatus.toUpperCase()}`);
  console.log('─'.repeat(50));
  for (const [, s] of Object.entries(stages)) {
    const dur = typeof s.durationSeconds === 'number' ? `  (${s.durationSeconds}s)` : '';
    console.log(`  ${stageEmoji(s.status)} ${s.label.padEnd(25)} ${s.status}${dur}`);
  }
  console.log('─'.repeat(50));
  console.log(`Commit: ${report.commit.slice(0, 8)}  Branch: ${report.branch}`);
  console.log(`Report: ${path.join(OUT_DIR, 'pipeline-report.json')}\n`);

  // Raportul se generează mereu cu succes — statusul e în JSON, nu în exit code
  console.log(`\nGitHub Pages report generat.`);
}

main();
