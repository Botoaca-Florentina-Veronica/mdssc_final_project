# MDSSC Jenkins Plugin & CI/CD Pipeline

[![CI/CD](https://github.com/ioanamhl/mdssc_project/actions/workflows/cicd.yml/badge.svg)](https://github.com/ioanamhl/mdssc_project/actions/workflows/cicd.yml)

A university project that integrates **OPSWAT MetaDefender Supply Chain Security (MDSSC)** into a Jenkins plugin and a full GitHub Actions CI/CD pipeline, including end-to-end tests and automated reporting.

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

The pipeline in `.github/workflows/cicd.yml` orchestrates the full plugin lifecycle on every push or pull request.

### Stages

| # | Stage | Description |
|---|-------|-------------|
| 1 | **Source Code Scan** | Run MDSSC scan on the plugin source code |
| 2 | **Build Plugin** | Compile the plugin and produce the `.hpi` artifact |
| 3 | **Artifact Scan** | Run MDSSC scan on the built `.hpi` file |
| 4 | **E2E Tests** | Execute the full E2E test suite against the plugin |
| 5 | **Report** | Publish pipeline status, E2E results, and the full testing report |

### Pipeline Flow

```yaml
on: [push, pull_request]

jobs:
  source-scan:    # MDSSC source code scan
  build:          # mvn package / gradle jpi → produces .hpi
  artifact-scan:  # MDSSC artifact scan on .hpi
  e2e-tests:      # Plugin E2E test suite
  report:         # Aggregate and publish results
```

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `MDSSC_INSTANCE` | MDSSC server URL |
| `MDSSC_API_KEY` | MDSSC API key |

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