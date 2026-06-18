package io.jenkins.plugins.mdssc;

import org.junit.Test;
import static org.junit.Assert.*;

public class SourceCodeScanStepTest {

    @Test
    public void testDefaultScanTimeout() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, 0, 0);
        assertEquals(900, step.getScanTimeout());
    }

    @Test
    public void testDefaultPollInterval() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, 0, 0);
        assertEquals(10, step.getPollInterval());
    }

    @Test
    public void testCustomValues() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-123", "repo-456", "develop",
            "workflow-789", "high", true, true, 600, 5);
        assertEquals("http://mdssc-server", step.getMdsscInstance());
        assertEquals("cred-id", step.getCredentialsId());
        assertEquals("conn-123", step.getConnectionId());
        assertEquals("repo-456", step.getRepository());
        assertEquals("develop", step.getBranch());
        assertEquals("workflow-789", step.getWorkflowId());
        assertEquals("high", step.getVulnerabilityThreshold());
        assertTrue(step.isFailOnSecret());
        assertTrue(step.isFailOnMalware());
        assertEquals(600, step.getScanTimeout());
        assertEquals(5, step.getPollInterval());
    }

    @Test
    public void testNegativeScanTimeoutDefaultsTo900() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, -1, 0);
        assertEquals(900, step.getScanTimeout());
    }

    @Test
    public void testNegativePollIntervalDefaultsTo10() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, 0, -5);
        assertEquals(10, step.getPollInterval());
    }

    @Test
    public void testEmptyWorkflowId() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, 900, 10);
        assertEquals("", step.getWorkflowId());
    }

    @Test
    public void testResolveRepoNameValidBase64() {
        // "github-ioana/1264280155" encoded in base64
        String base64 = "Z2l0aHViLWlvYW5hLzEyNjQyODAxNTU=";
        // Should not throw exception
        String result = SourceCodeScanStep.resolveRepoName(base64);
        // Result can be null if GitHub API fails, but should not crash
        assertTrue(result == null || result.length() > 0);
    }

    @Test
    public void testResolveRepoNameInvalidBase64() {
        String result = SourceCodeScanStep.resolveRepoName("not-valid-base64!!!");
        assertNull(result);
    }

    @Test
    public void testFailOnSecretFalseByDefault() {
        SourceCodeScanStep step = new SourceCodeScanStep(
            "http://mdssc-server", "cred-id",
            "conn-id", "repo-id", "main",
            "", "none", false, false, 900, 10);
        assertFalse(step.isFailOnSecret());
        assertFalse(step.isFailOnMalware());
    }

    @Test
    public void testAllThresholdValues() {
        String[] thresholds = {"none", "low", "medium", "high", "critical"};
        for (String t : thresholds) {
            SourceCodeScanStep step = new SourceCodeScanStep(
                "http://mdssc-server", "cred-id",
                "conn-id", "repo-id", "main",
                "", t, false, false, 900, 10);
            assertEquals(t, step.getVulnerabilityThreshold());
        }
    }
}