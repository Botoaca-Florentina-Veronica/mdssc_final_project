# MDSSC Scanner — Jenkins Plugin

A Jenkins plugin that integrates **MetaDefender Software Supply Chain (MDSSC)** security scanning directly into Jenkins pipelines and Freestyle jobs.

---

## What it does

The plugin adds two build steps to Jenkins:

| Step | What it scans | How |
|---|---|---|
| **Source Code Scan** | Your GitHub repository | MDSSC pulls the code directly from GitHub via a configured connection |
| **Artifact Scan** | A built file (`.jar`, `.hpi`, etc.) | The plugin uploads the file to MDSSC for analysis |

Both steps **block the build** if the scan results exceed the configured threshold — enforcing security gates automatically in CI/CD.

---

## How it works

### Source Code Scan — Indirect flow
```
Jenkins Plugin
    │
    ├─ 1. GET  /health  (or /version)         → health check
    │
    ├─ 2. Resolve storageId + repositoryId
    │       ├─ PRIMARY:   taken directly from UI fields (Connection + Repository)
    │       └─ FALLBACK:  if UI fields are empty but workflowId is set (e.g. CI/CD):
    │                       GET /workflows/{workflowId}
    │                           → extracts storageId + repositoryId
    │
    ├─ 3. GET  https://api.github.com/repositories/{id}
    │                                         → resolve friendly repo name (for report)
    │
    ├─ 4. POST /scans                         → start scan (MDSSC pulls from GitHub)
    │         body: { storageId, repositoryId,
    │                 repositoryReferences: [branch],
    │                 scanType: 0, workflowId?, repositoryName? }
    │
    └─ 5. GET  /scans/{id}/overview           → poll every 10s until Completed
              (fallback: GET /scans/{id})
              └─ evaluate results → PASS or FAIL build
```

### Artifact Scan — Direct flow
```
Jenkins Plugin
    │
    ├─ 1. GET  /health  (or /version)         → health check
    │
    ├─ 2. POST /scans/direct                  → upload file + start scan
    │         body: multipart/form-data
    │               part "workflowId" (if set)
    │               part "file" (binary content)
    │
    └─ 3. GET  /scans/{id}/overview           → poll every 10s until Completed
              (fallback: GET /scans/{id})
              └─ evaluate results → PASS or FAIL build
```

---

## Key features

- **Dynamic UI dropdowns** — Connection, Repository and Branch fields auto-populate from the MDSSC API when you open the job configuration form
- **Workflow auto-detection** — if no Workflow ID is provided, the plugin picks the default workflow automatically
- **Configurable thresholds** — choose at which severity level the build fails: `none / low / medium / high / critical`
- **Fail on Secret / Fail on Malware** — independent flags to block builds on security findings beyond vulnerabilities
- **Friendly repository names** — resolves base64-encoded repository IDs to readable names via GitHub API
- **Works in both Freestyle and Pipeline jobs**
- **Timeout and poll interval** — fully configurable per step

---

## Configuration — what each field means

| Field | Description |
|---|---|
| `mdsscInstance` | URL of the MDSSC server |
| `credentialsId` | Jenkins credential ID (Secret Text) holding the MDSSC API key |
| `workflowId` | MDSSC workflow to use — leave empty for default |
| `connectionId` | GitHub connection (storageId) — select from dropdown |
| `repository` | Repository to scan — select from dropdown |
| `branch` | Branch to scan — select from dropdown |
| `filePath` | Path to the artifact file relative to the Jenkins workspace |
| `vulnerabilityThreshold` | Severity level that fails the build |
| `failOnSecret` | Fail build if secrets are detected |
| `failOnMalware` | Fail build if malware is detected |
| `scanTimeout` | Max seconds to wait for scan completion (default: 900) |
| `pollInterval` | Seconds between status checks (default: 10) |
| `maxFileSizeMb` | Artifact scan only — files above this limit are skipped |

---

## Pipeline usage

### Source Code Scan

```groovy
stage('Source Code Scan') {
    steps {
        step([$class: 'SourceCodeScanStep',
            mdsscInstance:          'http://35.156.106.42/',
            credentialsId:          'mdssc-api-key',
            connectionId:           '019ea811-962e-7573-96af-735a2ca9ba17',
            repository:             'Z2l0aHViLWlvYW5hLzEyNjQyODAxNTU=',
            branch:                 'main',
            workflowId:             '',               // empty = use default workflow
            vulnerabilityThreshold: 'high',           // fail on high or critical
            failOnSecret:           true,
            failOnMalware:          true,
            scanTimeout:            900,
            pollInterval:           10
        ])
    }
}
```

### Artifact Scan

```groovy
stage('Artifact Scan') {
    steps {
        step([$class: 'ArtifactScanStep',
            mdsscInstance:          'http://35.156.106.42/',
            credentialsId:          'mdssc-api-key',
            filePath:               'target/app.jar',
            workflowId:             '',               // empty = use default workflow
            vulnerabilityThreshold: 'critical',       // fail only on critical
            failOnSecret:           true,
            failOnMalware:          true,
            scanTimeout:            900,
            pollInterval:           10,
            maxFileSizeMb:          100
        ])
    }
}
```

---

## What the scan checks

| Category | What is detected |
|---|---|
| **Vulnerabilities** | CVEs in dependencies (critical / high / medium / low) |
| **Malware** | Known malicious code patterns |
| **Secrets** | Hardcoded API keys, tokens, passwords |
| **License Risk** | Dependencies with blocked or incompatible licenses |

---

## Scan result — what the plugin reads from MDSSC

The plugin reads from `GET /scans/{id}/overview` and parses:

```
ScanInformation
    ├── VulnerabilityIssues → critical, high, medium, low
    ├── Malware             → true / false
    ├── Secret              → true / false
    └── Licenses
            └── BlockedLicensesCount → number
```

---

## Private repositories

- **Artifact Scan** — always works, the file is uploaded directly, GitHub is never accessed
- **Source Code Scan** — works if the MDSSC Connection (configured in MDSSC UI) has a GitHub token with access to the private repository. If the repository appears in the dropdown, the token already has access.

---

## Installation

1. Build the plugin: `mvn clean package -DskipTests` (requires Java 17)
2. In Jenkins → **Manage Jenkins → Manage Plugins → Advanced → Upload Plugin**
3. Upload `target/mdssc-plugin.hpi`
4. Restart Jenkins
5. Add a **Secret Text** credential with your MDSSC API key (ID: `mdssc-api-key`)
