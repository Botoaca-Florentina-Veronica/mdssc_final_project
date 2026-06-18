# MDSSC Plugin — Test Report

## Overview
This document describes the test suite implemented for the MDSSC Jenkins Plugin (Track C).
All tests are located in `plugin/src/test/java/io/jenkins/plugins/mdssc/`.

## Test Results Summary

| Test Class | Tests | Status | Tool |
|---|---|---|---|
| VulnerabilityThresholdTest | 12 | ✅ PASS | JUnit |
| ArtifactScanStepTest | 8 | ✅ PASS | JUnit |
| SourceCodeScanStepTest | 10 | ✅ PASS | JUnit |
| FormValidationTest | 17 | ✅ PASS | JUnit |
| JenkinsIntegrationTest | 10 | ✅ PASS | Jenkins Test Harness |
| InjectedTest | 6 | ✅ PASS | Jenkins Test Harness |
| **TOTAL** | **57** | **✅ ALL PASS** | |

---

## Test Classes

### 1. VulnerabilityThresholdTest
Tests the core threshold logic of the plugin.

| Test | Description |
|---|---|
| testNoneNeverFails | NONE threshold never fails regardless of vulnerabilities |
| testCriticalOnlyFailsOnCritical | CRITICAL threshold fails only on critical vulns |
| testHighFailsOnHighAndCritical | HIGH threshold fails on high and critical |
| testMediumFailsOnMediumHighCritical | MEDIUM threshold fails on medium, high, critical |
| testLowFailsOnAnything | LOW threshold fails on any vulnerability |
| testCriticalDoesNotFailOnHighOnly | CRITICAL ignores high vulnerabilities |
| testHighDoesNotFailOnMediumOnly | HIGH ignores medium vulnerabilities |
| testLowFailsOnSingleLow | LOW fails on a single low vulnerability |
| testCriticalFailsOnSingleCritical | CRITICAL fails on a single critical vulnerability |
| testAllZeroesNeverFails | No vulnerabilities never triggers failure |
| testLargeNumbersHandledCorrectly | Large vulnerability counts handled correctly |
| testZeroVulnerabilitiesNeverFails | Zero vulnerabilities never fails any threshold |

---

### 2. ArtifactScanStepTest
Tests parameter handling and default values for ArtifactScanStep.

| Test | Description |
|---|---|
| testDefaultScanTimeout | scanTimeout defaults to 900 when 0 is passed |
| testDefaultPollInterval | pollInterval defaults to 10 when 0 is passed |
| testDefaultMaxFileSizeMb | maxFileSizeMb defaults to 100 when 0 is passed |
| testCustomValues | All custom values are stored correctly |
| testNegativeScanTimeoutDefaultsTo900 | Negative scanTimeout defaults to 900 |
| testNegativePollIntervalDefaultsTo10 | Negative pollInterval defaults to 10 |
| testNegativeMaxFileSizeDefaultsTo100 | Negative maxFileSizeMb defaults to 100 |
| testEmptyWorkflowId | Empty workflowId is stored as empty string |

---

### 3. SourceCodeScanStepTest
Tests parameter handling and default values for SourceCodeScanStep.

| Test | Description |
|---|---|
| testDefaultScanTimeout | scanTimeout defaults to 900 when 0 is passed |
| testDefaultPollInterval | pollInterval defaults to 10 when 0 is passed |
| testCustomValues | All custom values are stored correctly |
|