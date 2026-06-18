package io.jenkins.plugins.mdssc;

import hudson.util.FormValidation;
import org.junit.Test;
import static org.junit.Assert.*;

public class FormValidationTest {

    private final ArtifactScanStep.DescriptorImpl artifactDesc = 
        new ArtifactScanStep.DescriptorImpl();
    private final SourceCodeScanStep.DescriptorImpl sourceDesc = 
        new SourceCodeScanStep.DescriptorImpl();

    // ── MDSSC Instance URL validation ──

    @Test
    public void testEmptyUrlReturnsError() {
        FormValidation result = artifactDesc.doCheckMdsscInstance("");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testNullUrlReturnsError() {
        FormValidation result = artifactDesc.doCheckMdsscInstance(null);
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testValidHttpUrlReturnsOk() {
        FormValidation result = artifactDesc.doCheckMdsscInstance("http://35.156.106.42");
        assertEquals(FormValidation.Kind.OK, result.kind);
    }

    @Test
    public void testValidHttpsUrlReturnsOk() {
        FormValidation result = artifactDesc.doCheckMdsscInstance("https://mdssc.example.com");
        assertEquals(FormValidation.Kind.OK, result.kind);
    }

    @Test
    public void testUrlWithoutProtocolReturnsWarning() {
        FormValidation result = artifactDesc.doCheckMdsscInstance("35.156.106.42");
        assertEquals(FormValidation.Kind.WARNING, result.kind);
    }

    @Test
    public void testFtpUrlReturnsWarning() {
        FormValidation result = artifactDesc.doCheckMdsscInstance("ftp://35.156.106.42");
        assertEquals(FormValidation.Kind.WARNING, result.kind);
    }

    // ── File path validation ──

    @Test
    public void testEmptyFilePathReturnsError() {
        FormValidation result = artifactDesc.doCheckFilePath("");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testNullFilePathReturnsError() {
        FormValidation result = artifactDesc.doCheckFilePath(null);
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testValidFilePathReturnsOk() {
        FormValidation result = artifactDesc.doCheckFilePath("target/mdssc-scanner.hpi");
        assertEquals(FormValidation.Kind.OK, result.kind);
    }

    // ── Max file size validation ──

    @Test
    public void testZeroFileSizeReturnsError() {
        FormValidation result = artifactDesc.doCheckMaxFileSizeMb("0");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testNegativeFileSizeReturnsError() {
        FormValidation result = artifactDesc.doCheckMaxFileSizeMb("-1");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testValidFileSizeReturnsOk() {
        FormValidation result = artifactDesc.doCheckMaxFileSizeMb("100");
        assertEquals(FormValidation.Kind.OK, result.kind);
    }

    @Test
    public void testNonNumericFileSizeReturnsError() {
        FormValidation result = artifactDesc.doCheckMaxFileSizeMb("abc");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testEmptyFileSizeReturnsError() {
        FormValidation result = artifactDesc.doCheckMaxFileSizeMb("");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    // ── SourceCodeScan credentials validation ──

    @Test
    public void testEmptyCredentialsIdReturnsError() {
        FormValidation result = sourceDesc.doCheckCredentialsId("");
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testNullCredentialsIdReturnsError() {
        FormValidation result = sourceDesc.doCheckCredentialsId(null);
        assertEquals(FormValidation.Kind.ERROR, result.kind);
    }

    @Test
    public void testValidCredentialsIdReturnsOk() {
        FormValidation result = sourceDesc.doCheckCredentialsId("mdssc-api-key");
        assertEquals(FormValidation.Kind.OK, result.kind);
    }
}