# MDSSC Jenkins Plugin & CI/CD Pipeline

[![CI/CD](https://github.com/Botoaca-Florentina-Veronica/mdssc_final_project/actions/workflows/cicd.yml/badge.svg)](https://github.com/Botoaca-Florentina-Veronica/mdssc_final_project/actions/workflows/cicd.yml)

A university project that integrates **OPSWAT MetaDefender Software Supply Chain (MDSSC)** into a Jenkins plugin and a full GitHub Actions CI/CD pipeline, including end-to-end tests and automated reporting.

The project is split into four tracks:

| Track | Scope |
|-------|-------|
| **A** | MDSSC Jenkins Plugin (`.hpi`) with Source Code & Artifact scanning steps |
| **B** | GitHub Actions CI/CD pipeline that builds, scans, and tests the plugin |
| **C** | End-to-end test suite for the Jenkins plugin |
| **D** *(optional)* | Demo Jenkins pipeline using the plugin directly (checkout → scan → build → deploy) |

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Track A — Jenkins Plugin](#track-a--jenkins-plugin)
   - [Build Steps](#build-steps)
   - [Source Code Scan Step](#source-code-scan-step)
   - [Artifact Scan Step](#artifact-scan-step)
   - [Execution Flow](#execution-flow)
3. [Track B — GitHub Actions CI/CD Pipeline](#track-b--github-actions-cicd-pipeline)
4. [Track C — E2E Tests](#track-c--e2e-tests)
5. [Track D — Demo Pipeline (Optional)](#track-d--demo-pipeline-optional)
6. [MDSSC API Reference](#mdssc-api-reference)
7. [Repository Structure](#repository-structure)
8. [Team Responsibilities](#team-responsibilities)

---

## Architecture Overview

```
PUSH ──> GITHUB ACTIONS (outer orchestrator)
              │
              ├── Source Code Scan     (MDSSC, plugin source)
              │
              ├── Build Plugin (.hpi)
              │
              ├── Artifact Scan        (MDSSC, built .hpi)
              │
              ├── E2E Tests            (Jenkins plugin test suite)
              │
              └── Report               (Pipeline status, E2E results, testing report)
```

The whiteboard diagram below captures the high-level flow agreed by the team:

```
Jenkins Plugin ←── CODE SCAN ──> Build .hpi ──> TEST .hpi ──> Artifact Scan ──> REPORT
      │                │                │               │              │
   GitHub          MDSSC scan      API test        API upload     Pipeline status
                   on results      harness         + pipeline     E2E tests
                                Threshold test       tests        Testing report
                                Fail on vuln.
```

---

## Track A — Jenkins Plugin

### Overview

The plugin ships as a standard `.hpi` file and adds **two custom build steps** to the Jenkins job UI:

- **MDSSC Source Code Scan** — scans a repository branch before build
- **MDSSC Artifact Scan** — scans a built file (archive, Docker image, etc.) after build

Both steps share common security gate parameters (vulnerability threshold, fail-on-secret, fail-on-malware).

---

### Build Steps

#### Source Code Scan Step

| Parameter | Type | Description |
|-----------|------|-------------|
| `MDSSC Instance` | URL | Base URL of the MDSSC server (e.g. `https://mdssc.example.com`) |
| `MDSSC API Key` | Secret | API key for authentication |
| `Connection ID` | Dropdown *(if viable)* | Select a pre-configured source connection from MDSSC |
| `Repository` | Dropdown *(if viable)* | Repository name or URL |
| `Branch` | Dropdown *(if viable)* | Branch to scan |
| `Workflow ID` | String *(optional)* | Custom workflow; uses the MDSSC default workflow if not set |
| `Vulnerability Threshold` | Enum | `critical` / `high` / `medium` / `low` / `unknown` / `none` |
| `Fail on Secret` | Boolean | Fail the build if secrets are detected |
| `Fail on Malware` | Boolean | Fail the build if malware is detected |

> **Dropdown viability:** The plugin will attempt to populate Connection, Repository, and Branch dropdowns by querying the MDSSC API at configuration time. If the instance is unreachable, fields fall back to free-text inputs.

---

#### Artifact Scan Step

| Parameter | Type | Description |
|-----------|------|-------------|
| `MDSSC Instance` | URL | Base URL of the MDSSC server |
| `MDSSC API Key` | Secret | API key for authentication |
| `File Path` | String | Workspace-relative path to the artifact (`.hpi`, `.tar.gz`, Docker image, etc.) |
| `Workflow ID` | String *(optional)* | Custom workflow; uses the MDSSC default workflow if not set |
| `Vulnerability Threshold` | Enum | `critical` / `high` / `medium` / `low` / `unknown` / `none` |
| `Fail on Secret` | Boolean | Fail the build if secrets are detected |
| `Fail on Malware` | Boolean | Fail the build if malware is detected |

---

### Execution Flow

Both build steps follow the same internal sequence:

```
1. Health Check
   └── GET /api/v1/health
       Verify the MDSSC instance is reachable before starting.

2. Start Scan
   ├── Source step → POST /api/v1/scans  (indirect, via repo/branch reference)
   └── Artifact step → POST /api/v1/scans/direct  (direct file upload)

3. Poll Results
   └── GET /api/v1/scans/{id}/overview  (repeated until status ≠ IN_PROGRESS)

4. Fetch Detailed Results
   └── GET /api/v1/scans/{id}

5. Report & Gate
   ├── Print a breakdown: vulnerability counts by severity, secrets found, malware found
   ├── Compare against configured thresholds
   └── Fail the build (exit non-zero) if any threshold is exceeded
```

---

## Track B — GitHub Actions CI/CD Pipeline

GitHub Actions is the main orchestrator of this project. The pipeline defined in `.github/workflows/cicd.yml` runs automatically on every `push` and `pull_request`, covering the full lifecycle of the Jenkins plugin — from source code security scanning through build, artifact scanning, end-to-end tests, and final reporting. All stages are connected in a dependency chain; if a security gate fails the pipeline stops, but the Report stage and GitHub Pages deployment always run so the results are always published.

### Stages

| # | Stage | Description |
|---|-------|-------------|
| 1 | **Source Code Scan** | Indirect MDSSC scan — MDSSC pulls the repository from GitHub and analyzes the source code |
| 2 | **Security Scan** | `npm audit` on the E2E test dependencies (runs in parallel with Stage 1) |
| 3 | **Build Plugin** | Compile the Jenkins plugin with Maven and produce the `.hpi` artifact |
| 4 | **Artifact Scan** | Direct MDSSC scan — the `.hpi` file is uploaded to MDSSC for binary analysis |
| 5 | **E2E Tests** | Full end-to-end test suite against the plugin and a live Jenkins instance |
| 6 | **Report** | Aggregate results, generate the pipeline report, and publish to GitHub Pages |

### Stage Details

**Stage 1 — Source Code Scan (indirect)**

This is an *indirect* scan: the pipeline does not upload any files to MDSSC. Instead, it sends a `POST /api/v1/scans` request containing the repository branch name and the pre-configured `MDSSC_WORKFLOW_ID`. The workflow stored in MDSSC already holds the connection to the GitHub repository (OAuth credentials, repository URL), so MDSSC connects back to GitHub, pulls the specified branch, and runs its full analysis — detecting vulnerabilities in third-party dependencies, searching for hardcoded secrets, and checking for malware.

The pipeline receives a scan ID in the response field `ScanIds[0]`, then polls `GET /api/v1/scans/{id}/overview` at a configurable interval until the scan status leaves the `Running` state. Once complete, the final result is read from `GET /api/v1/scans/{id}` and the security gate is applied: if the vulnerability severity exceeds the configured threshold, or if secrets or malware are found with the corresponding fail flags enabled, the stage fails and blocks all downstream stages.

**Stage 2 — Security Scan**

Runs `npm audit` on the `e2e/` test dependencies to detect publicly known vulnerabilities in the test toolchain. This stage runs in parallel with Stage 1 so it does not add to the total pipeline wall-clock time.

**Stage 3 — Build Plugin (.hpi)**

After both Stages 1 and 2 pass, Maven builds the Jenkins plugin from source (`mvn package`) and produces `mdssc-plugin.hpi`. If the plugin source is not yet present in the repository (Track A is developed by a separate team member), a minimal placeholder `.hpi` is generated from a stub `MANIFEST.MF` so the rest of the pipeline can still exercise all subsequent stages without blocking on Track A completion.

**Stage 4 — Artifact Scan (direct)**

This is a *direct* scan: the `.hpi` file built in Stage 3 is uploaded as a byte stream to `POST /api/v1/scans/direct`. MDSSC unpacks the archive, inspects the embedded JARs and resources for vulnerabilities, secrets, and malware, and returns a scan ID. The same polling and security gate logic from Stage 1 applies. The resulting scan ID is saved and combined with `MDSSC_INSTANCE` and `REPOSITORY_ID` to generate a deep link to the scan report in the MDSSC dashboard, which is then surfaced in the GitHub Pages deployment.

**Stage 5 — E2E Tests**

Executes the end-to-end test suite from `e2e/`. See [Track C](#track-c--e2e-tests) for the full test plan, including the planned Jenkins integration tests.

**Stage 6 — Report & GitHub Pages**

Always runs regardless of whether earlier stages passed or failed (`if: always()`). `ci/scripts/generate-report.js` collects the outputs of all previous stages — MDSSC scan JSON files, `npm audit` results, E2E test results — and writes a unified `pipeline-report.json`. This file is read at runtime by the GitHub Pages site (`docs/index.html`), which renders a visual pipeline diagram showing the status of each stage, vulnerability counts, and direct links to each MDSSC scan report. The GitHub Pages site is deployed on every push to `main` regardless of pipeline outcome, so results are always visible even after a failure.

### Pipeline Flow

```yaml
on: [push, pull_request]

jobs:
  source-scan:    # Stage 1 — indirect MDSSC source code scan
  security-scan:  # Stage 2 — npm audit (runs in parallel with source-scan)
  build:          # Stage 3 — mvn package → produces .hpi
  artifact-scan:  # Stage 4 — direct MDSSC artifact scan on .hpi
  e2e-tests:      # Stage 5 — plugin E2E test suite
  report:         # Stage 6 — aggregate results and deploy to GitHub Pages
```

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `MDSSC_INSTANCE` | Base URL of the MDSSC server (e.g. `https://mdssc.example.com`) |
| `MDSSC_API_KEY` | API key for authenticating with the MDSSC REST API |
| `MDSSC_WORKFLOW_ID` | MDSSC workflow ID used by both source code and artifact scans |
| `REPOSITORY_ID` | MDSSC repository ID — used to build deep links to scan reports in the GitHub Pages dashboard |

---

## Track C — E2E Tests

The test suite lives in `e2e/` and covers all plugin behaviour end-to-end against a real (or stubbed) MDSSC instance and Jenkins server.

### Common Tests (both steps)

**Vulnerability threshold tests**

- Build fails when scan result exceeds `critical` threshold
- Build fails when scan result exceeds `high` threshold
- Build fails when scan result exceeds `medium` threshold
- Build fails when scan result exceeds `low` threshold
- Build fails when scan result has `unknown` severity and threshold is `unknown`
- Build succeeds when threshold is `none` regardless of findings

**Secrets tests**

- Build fails when secrets are detected and `Fail on Secret` is enabled
- Build succeeds when secrets are detected but `Fail on Secret` is disabled

**Malware tests**

- Build fails when malware is detected and `Fail on Malware` is enabled
- Build succeeds when malware is detected but `Fail on Malware` is disabled

**Bad input tests**

- Correct error message on invalid API key
- Correct error message on unreachable MDSSC URL
- Correct error message on malformed MDSSC instance URL
- Correct error message on missing required fields

---

### Source Code Scan Step Tests

| Test | Expected Behaviour |
|------|--------------------|
| Repository not found | Build fails with `Repository not found` message |
| Branch not found | Build fails with `Branch not found` message |
| Connection ID invalid | Build fails with descriptive error |
| Workflow ID not found | Build fails with `Workflow not found` message |
| Default workflow used when Workflow ID omitted | Build proceeds using MDSSC default workflow |

---

### Artifact Scan Step Tests

| Test | Expected Behaviour |
|------|--------------------|
| File not found at path | Build fails with `File not found` message |
| File exceeds size limit | Build fails with `File too large` message |
| Unsupported file type | Build fails with appropriate error |
| Workflow ID not found | Build fails with `Workflow not found` message |
| Default workflow used when Workflow ID omitted | Build proceeds using MDSSC default workflow |

---

### Jenkins Integration Tests (planned)

In addition to the API-level tests above, the test suite will include a set of integration tests that install a full Jenkins instance directly on the GitHub Actions Ubuntu runner and validate the plugin end-to-end in a realistic Jenkins environment. The planned implementation follows these steps:

1. **Provision Jenkins** — Download `jenkins.war` and start it on a random local port. The test harness polls the Jenkins health check endpoint (`/login`) until the server is ready to accept connections.

2. **Initial configuration** — Disable the first-run setup wizard, create an admin account, and configure security using the Jenkins CLI (`jenkins-cli.jar`) or the Jenkins REST API (`/securityRealm/createAccountByAdmin`).

3. **Install the plugin** — Upload `mdssc-plugin.hpi` (the artifact produced by Stage 3 of the pipeline) via `POST /pluginManager/uploadPlugin` and trigger a Jenkins restart to activate it.

4. **Create and run a test job** — Create a Freestyle or Pipeline job that includes the plugin's build steps (MDSSC Source Code Scan or MDSSC Artifact Scan) by POSTing a `config.xml` to `/createItem`. Trigger the job via `POST /job/{name}/build` and wait for it to complete by polling `/job/{name}/lastBuild/api/json`.

5. **Assert the outcome** — A test is considered passed or failed as follows:
   - **Expected success**: the Jenkins build result is `SUCCESS` and the plugin's console log contains the expected MDSSC vulnerability summary with no threshold violations.
   - **Expected failure**: the Jenkins build result is `FAILURE` and the plugin's console log contains the specific error message corresponding to the injected condition (threshold exceeded, secret detected, malware found, unreachable instance, etc.).

This approach ensures the plugin behaves correctly not only against the MDSSC API in isolation but also when loaded by Jenkins and executed through Jenkins' own build lifecycle, including credential resolution, workspace management, and build-step chaining.

---

## Track D — Demo Pipeline *(Optional)*

A cosmetic end-to-end Jenkins pipeline demonstrating the plugin in a realistic application context. Steps may be faked or stubbed where infrastructure is unavailable.

```groovy
pipeline {
    agent any
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        stage('MDSSC Source Code Scan') {
            steps {
                mdsscSourceScan(
                    instance: env.MDSSC_INSTANCE,
                    apiKey: credentials('mdssc-api-key'),
                    repository: 'my-app',
                    branch: env.BRANCH_NAME,
                    vulnerabilityThreshold: 'high',
                    failOnSecret: true,
                    failOnMalware: true
                )
            }
        }
        stage('Build') {
            steps {
                sh 'npm ci && npm run build'
            }
        }
        stage('MDSSC Artifact Scan') {
            steps {
                mdsscArtifactScan(
                    instance: env.MDSSC_INSTANCE,
                    apiKey: credentials('mdssc-api-key'),
                    filePath: 'dist/app.tar.gz',
                    vulnerabilityThreshold: 'high',
                    failOnSecret: true,
                    failOnMalware: true
                )
            }
        }
        stage('Deploy') {
            steps {
                sh './scripts/deploy.sh'
            }
        }
    }
}
```

---

## MDSSC API Reference

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/health` | Health check — verify instance reachability |
| `GET` | `/api/v1/workflows/{workflowId}` | Fetch workflow metadata (StorageId, RepositoryId) |
| `POST` | `/api/v1/scans/direct` | Direct file upload and scan initiation |
| `GET` | `/api/v1/scans/{id}/overview` | Poll scan status |
| `GET` | `/api/v1/scans/{id}` | Fetch full scan result with vulnerability breakdown |
| `POST` | `/api/v1/scans` | Indirect scan via repository/branch reference |

---

## Repository Structure

```
mdssc_project/
├── .github/
│   └── workflows/
│       └── cicd.yml          # GitHub Actions pipeline (Track B)
├── ci/
│   ├── Jenkinsfile           # Jenkins pipeline stages
│   └── mdsscAdvanced.groovy  # MDSSC helper library (scan, poll, report)
├── e2e/
│   ├── playwright.config.js  # E2E test configuration
│   └── tests/
│       ├── common/           # Threshold, secrets, malware, bad-input tests
│       ├── sourcescan/       # Source Code Scan step tests
│       └── artifactscan/     # Artifact Scan step tests
├── backend/                  # Demo application — Node.js + Express + MongoDB
├── frontend/                 # Demo application — React + Vite
├── test-results/             # Published E2E and scan reports
├── docker-compose.yml
├── workflows.md
└── README.md
```

---

## Team Responsibilities

### Vera — Infrastructure & Jenkins

- Provision cloud VM (DigitalOcean Droplet)
- Install and configure Jenkins, Node.js, MongoDB, Nginx, PM2
- Configure Jenkins credentials and plugin management
- Write infrastructure documentation

### Ioana — GitHub & Pipeline

- Maintain the GitHub repository and branch strategy
- Write and maintain `Jenkinsfile` and `mdsscAdvanced.groovy`
- Configure GitHub → Jenkins webhook
- Track A plugin development

### Adi — GitHub Actions Workflows

- Write `.github/workflows/cicd.yml` (Track B)
- Configure status badges and release automation
- Ensure Actions trigger correctly on push and pull request

### Mario — E2E Tests & Reporting

- Implement the E2E test suite in `e2e/` (Track C)
- Integrate scan result reporting into the pipeline
- Document how to interpret test reports

---

## License

This project is developed as a university coursework submission. All MDSSC API interactions are subject to the OPSWAT MetaDefender Supply Chain Security terms of service.