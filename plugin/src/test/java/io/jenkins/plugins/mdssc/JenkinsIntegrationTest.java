package io.jenkins.plugins.mdssc;

import hudson.model.FreeStyleBuild;
import hudson.model.FreeStyleProject;
import hudson.model.Result;
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl;
import com.cloudbees.plugins.credentials.CredentialsScope;
import com.cloudbees.plugins.credentials.SystemCredentialsProvider;
import hudson.util.Secret;
import org.junit.Rule;
import org.junit.Test;
import org.jvnet.hudson.test.JenkinsRule;

import static org.junit.Assert.*;

public class JenkinsIntegrationTest {

    @Rule
    public JenkinsRule jenkins = new JenkinsRule();

    private static final String MDSSC_URL = "http://35.156.106.42";
    private static final String CRED_ID = "mdssc-api-key";
    private static final String API_KEY = "7pmD5MqXtLKXjFZ0qEoHayk8gdYdXdjjzHAj";

    // Helper: adds MDSSC API key as a Jenkins credential
    private void addCredential(String apiKey) throws Exception {
        StringCredentialsImpl cred = new StringCredentialsImpl(
            CredentialsScope.GLOBAL,
            CRED_ID,
            "MDSSC API Key",
            Secret.fromString(apiKey)
        );
        SystemCredentialsProvider.getInstance()
            .getCredentials().add(cred);
        SystemCredentialsProvider.getInstance().save();
    }

    // ── 1. Plugin registration ──────────────────────────────────────────────

    @Test
    public void testArtifactScanStepIsRegistered() {
        // Verifies that ArtifactScanStep is properly registered as a Jenkins build step
        ArtifactScanStep.DescriptorImpl desc =
            jenkins.jenkins.getDescriptorByType(ArtifactScanStep.DescriptorImpl.class);
        assertNotNull(desc);
    }

    @Test
    public void testSourceCodeScanStepIsRegistered() {
        // Verifies that SourceCodeScanStep is properly registered as a Jenkins build step
        SourceCodeScanStep.DescriptorImpl desc =
            jenkins.jenkins.getDescriptorByType(SourceCodeScanStep.DescriptorImpl.class);
        assertNotNull(desc);
    }

    @Test
    public void testArtifactScanStepDisplayName() {
        // Verifies the display name shown in Jenkins UI is not empty
        ArtifactScanStep.DescriptorImpl desc =
            jenkins.jenkins.getDescriptorByType(ArtifactScanStep.DescriptorImpl.class);
        assertNotNull(desc);
        assertFalse(desc.getDisplayName().isEmpty());
    }

    @Test
    public void testSourceCodeScanStepDisplayName() {
        // Verifies the display name shown in Jenkins UI is not empty
        SourceCodeScanStep.DescriptorImpl desc =
            jenkins.jenkins.getDescriptorByType(SourceCodeScanStep.DescriptorImpl.class);
        assertNotNull(desc);
        assertFalse(desc.getDisplayName().isEmpty());
    }

    // ── 2. Bad inputs → FAILURE ─────────────────────────────────────────────

    @Test
    public void testJobFailsWithInvalidMdsscUrl() throws Exception {
        // Client misconfigures MDSSC URL — job should fail gracefully
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            "http://invalid-url-that-does-not-exist:9999",
            CRED_ID,
            "file.hpi",
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    @Test
    public void testJobFailsWithEmptyMdsscUrl() throws Exception {
        // Client leaves MDSSC URL empty — job should fail
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            "",
            CRED_ID,
            "file.hpi",
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    @Test
    public void testJobFailsWithMissingCredentials() throws Exception {
        // Client sets wrong credentials ID — job should fail
        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            MDSSC_URL,
            "credentials-that-do-not-exist",
            "file.hpi",
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    @Test
    public void testJobFailsWithMissingFile() throws Exception {
        // Client sets a file path that does not exist in workspace — job should fail
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            MDSSC_URL,
            CRED_ID,
            "file-that-does-not-exist.hpi",
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    @Test
    public void testJobFailsWithNullFilePath() throws Exception {
        // Client passes null as file path — job should fail
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            MDSSC_URL,
            CRED_ID,
            null,
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    // ── 3. Threshold behavior ────────────────────────────────────────────────

    @Test
    public void testJobWithThresholdNoneAndMissingFile() throws Exception {
        // Even with threshold=none, missing file should still fail
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();
        project.getBuildersList().add(new ArtifactScanStep(
            MDSSC_URL,
            CRED_ID,
            "nonexistent.hpi",
            "", "none",
            false, false,
            30, 5, 100
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.FAILURE, build.getResult());
    }

    // ── 4. File size limit ───────────────────────────────────────────────────

    @Test
    public void testJobMarkedUnstableWhenFileExceedsLimit() throws Exception {
        // When file exceeds maxFileSizeMb limit, job should be marked UNSTABLE
        addCredential(API_KEY);

        FreeStyleProject project = jenkins.createFreeStyleProject();

        // Run a first empty build to initialize the workspace
        jenkins.buildAndAssertSuccess(project);

        // Create a 2MB file directly in workspace using Java
        java.io.File bigFile = new java.io.File(
            project.getSomeWorkspace().getRemote(), "bigfile.hpi");
        byte[] data = new byte[2 * 1024 * 1024];
        java.util.Arrays.fill(data, (byte) 'A');
        java.nio.file.Files.write(bigFile.toPath(), data);

        // Now add scan step with 1MB limit — should trigger UNSTABLE
        project.getBuildersList().add(new ArtifactScanStep(
            MDSSC_URL,
            CRED_ID,
            "bigfile.hpi",
            "", "none",
            false, false,
            30, 5, 1
        ));

        FreeStyleBuild build = project.scheduleBuild2(0).get();
        assertEquals(Result.UNSTABLE, build.getResult());
    }
}