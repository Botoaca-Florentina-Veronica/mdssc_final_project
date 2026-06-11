'use strict';

// Reusable scan result factories used by the mock MDSSC server.

function makeScan(id, overrides = {}) {
  return {
    id,
    status: 'COMPLETED',
    summary: { critical: 0, high: 0, medium: 0, low: 0, unknown: 0 },
    secrets: 0,
    malware: 0,
    ...overrides,
  };
}

const SCANS = {
  'clean':                  makeScan('clean'),
  'has-critical':           makeScan('has-critical',  { summary: { critical: 2, high: 0, medium: 0, low: 0, unknown: 0 } }),
  'has-high':               makeScan('has-high',      { summary: { critical: 0, high: 3, medium: 0, low: 0, unknown: 0 } }),
  'has-medium':             makeScan('has-medium',    { summary: { critical: 0, high: 0, medium: 4, low: 0, unknown: 0 } }),
  'has-low':                makeScan('has-low',       { summary: { critical: 0, high: 0, medium: 0, low: 5, unknown: 0 } }),
  'has-unknown':            makeScan('has-unknown',   { summary: { critical: 0, high: 0, medium: 0, low: 0, unknown: 1 } }),
  'has-secret':             makeScan('has-secret',    { secrets: 1 }),
  'has-malware':            makeScan('has-malware',   { malware: 1 }),
  'repo-not-found':         null,
  'branch-not-found':       null,
  'invalid-connection':     null,
  'workflow-not-found':     null,
  'file-not-found':         null,
  'file-too-large':         null,
  'unsupported-type':       null,
};

module.exports = { SCANS, makeScan };
