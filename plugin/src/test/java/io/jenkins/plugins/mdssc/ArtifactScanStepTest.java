package io.jenkins.plugins.mdssc;

import org.junit.Test;
import static org.junit.Assert.*;

public class ArtifactScanStepTest {

    @Test
    public void testDefaultScanTimeout() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 0, 0, 0);
        assertEquals(900, step.getScanTimeout());
    }

    @Test
    public void testDefaultPollInterval() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 0, 0, 0);
        assertEquals(10, step.getPollInterval());
    }

    @Test
    public void testDefaultMaxFileSizeMb() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 0, 0, 0);
        assertEquals(100, step.getMaxFileSizeMb());
    }

    @Test
    public void testCustomValues() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "workflow-123", "high", true, true, 300, 5, 50);
        assertEquals("http://mdssc-server", step.getMdsscInstance());
        assertEquals("cred-id", step.getCredentialsId());
        assertEquals("file.jar", step.getFilePath());
        assertEquals("workflow-123", step.getWorkflowId());
        assertEquals("high", step.getVulnerabilityThreshold());
        assertTrue(step.isFailOnSecret());
        assertTrue(step.isFailOnMalware());
        assertEquals(300, step.getScanTimeout());
        assertEquals(5, step.getPollInterval());
        assertEquals(50, step.getMaxFileSizeMb());
    }

    @Test
    public void testNegativeScanTimeoutDefaultsTo900() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, -1, 0, 0);
        assertEquals(900, step.getScanTimeout());
    }

    @Test
    public void testNegativePollIntervalDefaultsTo10() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 0, -5, 0);
        assertEquals(10, step.getPollInterval());
    }

    @Test
    public void testNegativeMaxFileSizeDefaultsTo100() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 0, 0, -10);
        assertEquals(100, step.getMaxFileSizeMb());
    }

    @Test
    public void testEmptyWorkflowId() {
        ArtifactScanStep step = new ArtifactScanStep(
            "http://mdssc-server", "cred-id", "file.jar",
            "", "none", false, false, 900, 10, 100);
        assertEquals("", step.getWorkflowId());
    }
}