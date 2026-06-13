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
  e2eTests: {
    label: 'E2E Tests',
    status: process.env.E2E_STATUS || 'skipped',
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

const overallStatus = Object.values(stages).every(s =>
  ['success', 'skipped'].includes(s.status)
) ? 'success' : 'failure';

// Extrage scan ID-urile din rezultatele MDSSC (câmpul ScanId sau id)
const sourceScanId  = stages.sourceCodeScan.result?.ScanId  || stages.sourceCodeScan.result?.id  || null;
const artifactScanId = stages.artifactScan.result?.ScanId   || stages.artifactScan.result?.id    || null;
const mdsscInstance  = (process.env.MDSSC_INSTANCE || '').replace(/\/$/, '');

const report = {
  generatedAt:   new Date().toISOString(),
  overallStatus,
  commit:  process.env.COMMIT_SHA || 'unknown',
  branch:  process.env.BRANCH     || 'unknown',
  repo:    process.env.REPO       || 'unknown',
  runUrl:  process.env.RUN_URL    || '#',
  mdsscInstance,
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
  console.log(`  ${stageEmoji(s.status)} ${s.label.padEnd(25)} ${s.status}`);
}
console.log('─'.repeat(50));
console.log(`Commit: ${report.commit.slice(0, 8)}  Branch: ${report.branch}`);
console.log(`Report: ${path.join(OUT_DIR, 'pipeline-report.json')}\n`);

// Raportul se generează mereu cu succes — statusul e în JSON, nu în exit code
console.log(`\nGitHub Pages report generat.`);
