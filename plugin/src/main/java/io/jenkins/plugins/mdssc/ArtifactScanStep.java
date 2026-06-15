package io.jenkins.plugins.mdssc;

import com.cloudbees.plugins.credentials.CredentialsProvider;
import com.cloudbees.plugins.credentials.common.StandardListBoxModel;
import hudson.EnvVars;
import hudson.Extension;
import hudson.FilePath;
import hudson.Launcher;
import hudson.model.*;
import hudson.security.ACL;
import hudson.tasks.BuildStepDescriptor;
import hudson.tasks.Builder;
import hudson.util.FormValidation;
import hudson.util.ListBoxModel;
import io.jenkins.plugins.mdssc.model.ScanResult;
import io.jenkins.plugins.mdssc.model.VulnerabilityThreshold;
import jenkins.model.Jenkins;
import jenkins.tasks.SimpleBuildStep;
import org.jenkinsci.plugins.plaincredentials.StringCredentials;
import org.kohsuke.stapler.DataBoundConstructor;
import org.kohsuke.stapler.QueryParameter;

import java.util.Collections;

import java.io.*;

public class ArtifactScanStep extends Builder implements SimpleBuildStep {

    private final String mdsscInstance;
    private final String credentialsId;
    private final String filePath;
    private final String workflowId;
    private final String vulnerabilityThreshold;
    private final boolean failOnSecret;
    private final boolean failOnMalware;
    private final int scanTimeout;
    private final int pollInterval;
    private final long maxFileSizeMb;

    @DataBoundConstructor
    public ArtifactScanStep(String mdsscInstance, String credentialsId,
            String filePath, String workflowId,
            String vulnerabilityThreshold,
            boolean failOnSecret, boolean failOnMalware,
            int scanTimeout, int pollInterval, long maxFileSizeMb) {
        this.mdsscInstance = mdsscInstance;
        this.credentialsId = credentialsId;
        this.filePath = filePath;
        this.workflowId = workflowId;
        this.vulnerabilityThreshold = vulnerabilityThreshold;
        this.failOnSecret = failOnSecret;
        this.failOnMalware = failOnMalware;
        this.scanTimeout = scanTimeout > 0 ? scanTimeout : 900;
        this.pollInterval = pollInterval > 0 ? pollInterval : 10;
        this.maxFileSizeMb = maxFileSizeMb > 0 ? maxFileSizeMb : 100;
    }

    @Override
    public void perform(Run<?, ?> run, FilePath workspace, EnvVars env,
            Launcher launcher, TaskListener listener)
            throws IOException, InterruptedException {
        PrintStream log = listener.getLogger();
        log.println("[MDSSC] ══════════════════════════════════════");
        log.println("[MDSSC]   Artifact Scan Step");
        log.println("[MDSSC] ══════════════════════════════════════");

        try {
            String apiKey = resolveApiKey(run);
            MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);

            // 1. Health check
            client.checkHealth(log);

            // 2. Resolve file path
            String resolvedPath = env.expand(filePath);
            FilePath target = workspace.child(resolvedPath);

            if (!target.exists()) {
                listener.error("[MDSSC] File not found: " + resolvedPath);
                run.setResult(Result.FAILURE);
                return;
            }

            // 3. Check file size
            long sizeBytes = target.length();
            long maxBytes = maxFileSizeMb * 1024 * 1024;
            if (sizeBytes > maxBytes) {
                log.printf("[MDSSC] WARNING: File too large (%d MB > %d MB limit) — skipping.%n",
                        sizeBytes / 1024 / 1024, maxFileSizeMb);
                run.setResult(Result.UNSTABLE);
                return;
            }

            // 4. Copy to local temp file
            File localFile = File.createTempFile("mdssc-", "-" + target.getName());
            localFile.deleteOnExit();
            try {
                target.copyTo(new FilePath(localFile));

                // 5. Start direct scan
                String scanId = client.scanFileDirect(localFile, workflowId, log);
                if (scanId == null || scanId.isBlank()) {
                    listener.error("[MDSSC] No scan ID returned.");
                    run.setResult(Result.FAILURE);
                    return;
                }
                log.printf("[MDSSC] Scan ID: %s%n", scanId);

                // 6. Poll until done
                ScanPoller poller = new ScanPoller(client, scanTimeout, pollInterval);
                ScanResult result = poller.pollUntilDone(scanId, target.getName(), log);

                // 7. Evaluate thresholds
                VulnerabilityThreshold threshold = VulnerabilityThreshold.valueOf(
                        vulnerabilityThreshold != null
                                ? vulnerabilityThreshold.toUpperCase()
                                : "NONE");
                poller.evaluateAndFail(result, target.getName(), threshold,
                        failOnSecret, failOnMalware, log);
            } finally {
                localFile.delete();
            }

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw e;
        } catch (Exception e) {
            listener.error("[MDSSC] Artifact scan failed: " + e.getMessage());
            run.setResult(Result.FAILURE);
        }
    }

    private String resolveApiKey(Run<?, ?> run) {
        StringCredentials cred = CredentialsProvider.findCredentialById(
                credentialsId, StringCredentials.class, run);
        if (cred == null)
            throw new RuntimeException("[MDSSC] Credentials not found: " + credentialsId);
        return cred.getSecret().getPlainText();
    }

    // ── Getters ───────────────────────────────────────────────
    public String getMdsscInstance() {
        return mdsscInstance;
    }

    public String getCredentialsId() {
        return credentialsId;
    }

    public String getFilePath() {
        return filePath;
    }

    public String getWorkflowId() {
        return workflowId;
    }

    public String getVulnerabilityThreshold() {
        return vulnerabilityThreshold;
    }

    public boolean isFailOnSecret() {
        return failOnSecret;
    }

    public boolean isFailOnMalware() {
        return failOnMalware;
    }

    public int getScanTimeout() {
        return scanTimeout;
    }

    public int getPollInterval() {
        return pollInterval;
    }

    public long getMaxFileSizeMb() {
        return maxFileSizeMb;
    }

    // ── Descriptor ────────────────────────────────────────────
    @Extension
    public static final class DescriptorImpl extends BuildStepDescriptor<Builder> {

        @Override
        public boolean isApplicable(Class<? extends AbstractProject> t) {
            return true;
        }

        @Override
        public String getDisplayName() {
            return "MDSSC — Artifact Scan";
        }

        public ListBoxModel doFillCredentialsIdItems() {
            return new StandardListBoxModel()
                    .withEmptySelection()
                    .withAll(CredentialsProvider.lookupCredentials(
                            StringCredentials.class,
                            Jenkins.get(),
                            ACL.SYSTEM,
                            Collections.emptyList()));
        }

        public ListBoxModel doFillVulnerabilityThresholdItems() {
            return new ListBoxModel(
                    new ListBoxModel.Option("None (never fail)", "none"),
                    new ListBoxModel.Option("Low", "low"),
                    new ListBoxModel.Option("Medium", "medium"),
                    new ListBoxModel.Option("High", "high"),
                    new ListBoxModel.Option("Critical", "critical"));
        }

        public FormValidation doCheckMdsscInstance(@QueryParameter String value) {
            if (value == null || value.isBlank())
                return FormValidation.error("MDSSC instance URL is required");
            if (!value.startsWith("http://") && !value.startsWith("https://"))
                return FormValidation.warning("URL should start with http:// or https://");
            return FormValidation.ok();
        }

        public FormValidation doCheckFilePath(@QueryParameter String value) {
            return (value == null || value.isBlank())
                    ? FormValidation.error("File path is required")
                    : FormValidation.ok();
        }

        public FormValidation doCheckMaxFileSizeMb(@QueryParameter String value) {
            try {
                long v = Long.parseLong(value);
                return v > 0 ? FormValidation.ok()
                        : FormValidation.error("Must be greater than 0");
            } catch (NumberFormatException e) {
                return FormValidation.error("Must be a number");
            }
        }
    }
}