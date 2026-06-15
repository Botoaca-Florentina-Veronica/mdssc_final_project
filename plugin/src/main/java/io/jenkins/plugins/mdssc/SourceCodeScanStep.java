package io.jenkins.plugins.mdssc;

import com.cloudbees.plugins.credentials.CredentialsProvider;
import com.cloudbees.plugins.credentials.common.StandardListBoxModel;
import hudson.EnvVars;
import hudson.Extension;
import hudson.FilePath;
import hudson.Launcher;
import hudson.model.*;
import hudson.tasks.BuildStepDescriptor;
import hudson.tasks.Builder;
import hudson.util.FormValidation;
import hudson.util.ListBoxModel;
import io.jenkins.plugins.mdssc.model.VulnerabilityThreshold;
import io.jenkins.plugins.mdssc.model.WorkflowInfo;
import io.jenkins.plugins.mdssc.model.ScanResult;
import jenkins.model.Jenkins;
import jenkins.tasks.SimpleBuildStep;
import org.jenkinsci.plugins.plaincredentials.StringCredentials;
import hudson.security.ACL;
import org.kohsuke.stapler.DataBoundConstructor;
import org.kohsuke.stapler.QueryParameter;

import java.io.*;
import java.util.Collections;

public class SourceCodeScanStep extends Builder implements SimpleBuildStep {

    private final String mdsscInstance;
    private final String credentialsId;
    private final String connectionId;
    private final String repository;
    private final String branch;
    private final String workflowId;
    private final String vulnerabilityThreshold;
    private final boolean failOnSecret;
    private final boolean failOnMalware;
    private final int scanTimeout;
    private final int pollInterval;

    @DataBoundConstructor
    public SourceCodeScanStep(String mdsscInstance, String credentialsId,
            String connectionId, String repository, String branch,
            String workflowId, String vulnerabilityThreshold,
            boolean failOnSecret, boolean failOnMalware,
            int scanTimeout, int pollInterval) {
        this.mdsscInstance = mdsscInstance;
        this.credentialsId = credentialsId;
        this.connectionId = connectionId;
        this.repository = repository;
        this.branch = branch;
        this.workflowId = workflowId;
        this.vulnerabilityThreshold = vulnerabilityThreshold;
        this.failOnSecret = failOnSecret;
        this.failOnMalware = failOnMalware;
        this.scanTimeout = scanTimeout > 0 ? scanTimeout : 900;
        this.pollInterval = pollInterval > 0 ? pollInterval : 10;
    }

    @Override
    public void perform(Run<?, ?> run, FilePath workspace, EnvVars env,
            Launcher launcher, TaskListener listener)
            throws IOException, InterruptedException {
        PrintStream log = listener.getLogger();
        log.println("[MDSSC] ══════════════════════════════════════");
        log.println("[MDSSC]   Source Code Scan Step");
        log.println("[MDSSC] ══════════════════════════════════════");

        try {
            String apiKey = resolveApiKey(run);
            MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);

            // 1. Health check
            client.checkHealth(log);

            // 2. Resolve workflow
            WorkflowInfo wf = client.resolveWorkflow(
                    workflowId != null && !workflowId.isBlank() ? workflowId : null, log);

            if (!wf.isValid()) {
                log.println("[MDSSC] WARNING: Workflow info incomplete — skipping scan.");
                run.setResult(Result.UNSTABLE);
                return;
            }

            // 3. Determine branch
            String effectiveBranch = (branch != null && !branch.isBlank())
                    ? branch
                    : env.get("GIT_BRANCH", env.get("BRANCH_NAME", "main"));
            if (effectiveBranch.startsWith("origin/"))
                effectiveBranch = effectiveBranch.substring(7);

            // 4. Start indirect scan
            String scanId = client.scanRepositoryIndirect(wf, effectiveBranch, log);
            if (scanId == null || scanId.isBlank()) {
                log.println("[MDSSC] WARNING: No scan ID returned.");
                run.setResult(Result.UNSTABLE);
                return;
            }
            log.printf("[MDSSC] Scan ID: %s%n", scanId);

            // 5. Poll until done
            ScanPoller poller = new ScanPoller(client, scanTimeout, pollInterval);
            ScanResult result = poller.pollUntilDone(scanId, "source-code", log);

            // 6. Evaluate thresholds
            VulnerabilityThreshold threshold = VulnerabilityThreshold.valueOf(
                    vulnerabilityThreshold != null
                            ? vulnerabilityThreshold.toUpperCase()
                            : "NONE");
            poller.evaluateAndFail(result, "source-code", threshold,
                    failOnSecret, failOnMalware, log);

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw e;
        } catch (Exception e) {
            listener.error("[MDSSC] Source code scan failed: " + e.getMessage());
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

    public String getConnectionId() {
        return connectionId;
    }

    public String getRepository() {
        return repository;
    }

    public String getBranch() {
        return branch;
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

    // ── Descriptor ────────────────────────────────────────────
    @Extension
    public static final class DescriptorImpl extends BuildStepDescriptor<Builder> {

        @Override
        public boolean isApplicable(Class<? extends AbstractProject> t) {
            return true;
        }

        @Override
        public String getDisplayName() {
            return "MDSSC — Source Code Scan";
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

        public ListBoxModel doFillConnectionIdItems(
                @QueryParameter String mdsscInstance,
                @QueryParameter String credentialsId,
                @QueryParameter String workflowId) {
            ListBoxModel m = new ListBoxModel();
            m.add("-- select connection --", "");
            try {
                String apiKey = resolveKey(credentialsId);
                if (apiKey.isBlank())
                    return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);
                var connections = client.listConnections(workflowId);
                if (connections.isArray()) {
                    for (var c : connections) {
                        String id = textOf(c, "id", "Id", "connectionId", "ConnectionId");
                        String name = textOf(c, "name", "Name", "connectionName", "ConnectionName");
                        m.add(name.isBlank() ? id : name + " (" + id + ")", id);
                    }
                }
            } catch (Exception ignored) {
                m.add("(error loading connections)", "");
            }
            return m;
        }

        public ListBoxModel doFillRepositoryItems(
                @QueryParameter String mdsscInstance,
                @QueryParameter String credentialsId,
                @QueryParameter String workflowId,
                @QueryParameter String connectionId) {
            ListBoxModel m = new ListBoxModel();
            m.add("-- select repository --", "");
            try {
                String apiKey = resolveKey(credentialsId);
                if (apiKey.isBlank())
                    return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);
                var repos = client.listRepositories(workflowId, connectionId);
                if (repos.isArray()) {
                    for (var r : repos) {
                        String id = textOf(r, "id", "Id", "repositoryId", "RepositoryId");
                        String name = textOf(r, "name", "Name", "repositoryName", "RepositoryName");
                        m.add(name.isBlank() ? id : name, id);
                    }
                }
            } catch (Exception ignored) {
                m.add("(error loading repositories)", "");
            }
            return m;
        }

        public ListBoxModel doFillBranchItems(
                @QueryParameter String mdsscInstance,
                @QueryParameter String credentialsId,
                @QueryParameter String repository) {
            ListBoxModel m = new ListBoxModel();
            m.add("-- select branch --", "");
            try {
                String apiKey = resolveKey(credentialsId);
                if (apiKey.isBlank())
                    return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);
                var branches = client.listBranches(repository);
                if (branches.isArray()) {
                    for (var b : branches) {
                        String name = textOf(b, "name", "Name", "branchName", "BranchName", "ref", "Ref");
                        m.add(name, name);
                    }
                }
            } catch (Exception ignored) {
                m.add("(error loading branches)", "");
            }
            return m;
        }

        public FormValidation doCheckMdsscInstance(@QueryParameter String value) {
            if (value == null || value.isBlank())
                return FormValidation.error("MDSSC instance URL is required");
            if (!value.startsWith("http://") && !value.startsWith("https://"))
                return FormValidation.warning("URL should start with http:// or https://");
            return FormValidation.ok();
        }

        public FormValidation doCheckCredentialsId(@QueryParameter String value) {
            return (value == null || value.isBlank())
                    ? FormValidation.error("API key credentials ID is required")
                    : FormValidation.ok();
        }

        private String resolveKey(String credId) {
            try {
                return Jenkins.get()
                        .getDescriptorByType(DescriptorImpl.class) != null
                                ? CredentialsProvider.lookupCredentials(
                                        StringCredentials.class, Jenkins.get(), null, Collections.emptyList())
                                        .stream()
                                        .filter(c -> c.getId().equals(credId))
                                        .findFirst()
                                        .map(c -> c.getSecret().getPlainText())
                                        .orElse("")
                                : "";
            } catch (Exception e) {
                return "";
            }
        }

        private String textOf(com.fasterxml.jackson.databind.JsonNode n, String... keys) {
            for (String k : keys)
                if (n.has(k) && n.get(k).isTextual())
                    return n.get(k).asText();
            return "";
        }
    }
}