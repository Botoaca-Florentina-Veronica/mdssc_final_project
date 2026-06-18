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
import com.fasterxml.jackson.databind.JsonNode;
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

            // 2. Determine storageId + repositoryId.
            //    Primary: from the Connection/Repository fields (selected in the UI).
            //    Fallback: if missing but a workflowId is given, resolve them from the workflow (CI).
            String storageId = (connectionId != null) ? connectionId.trim() : "";
            String repoId    = (repository   != null) ? repository.trim()   : "";
            if ((storageId.isBlank() || repoId.isBlank())
                    && workflowId != null && !workflowId.isBlank()) {
                log.println("[MDSSC] Connection/Repository empty — resolving from workflow " + workflowId);
                WorkflowInfo wf = client.resolveWorkflow(workflowId.trim(), log);
                if (storageId.isBlank()) storageId = wf.getStorageId();
                if (repoId.isBlank())    repoId    = wf.getRepositoryId();
            }
            if (storageId.isBlank() || repoId.isBlank()) {
                listener.error("[MDSSC] Connection/Repository are missing. Fill them in the UI "
                        + "or specify a WorkflowId from which they can be resolved.");
                run.setResult(Result.FAILURE);
                return;
            }

            // 3. Determine branch
            String effectiveBranch = (branch != null && !branch.isBlank())
                    ? branch
                    : env.get("GIT_BRANCH", env.get("BRANCH_NAME", "main"));
            if (effectiveBranch.startsWith("origin/"))
                effectiveBranch = effectiveBranch.substring(7);

            // 4. Start indirect scan (with a friendly name resolved from GitHub for the report)
            String wfId = (workflowId != null) ? workflowId.trim() : "";
            String repoName = resolveRepoName(repoId);
            String scanId = client.scanRepositoryIndirect(
                    storageId, repoId, repoName, wfId, effectiveBranch, log);
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

    // Decode base64 repoId → numeric GitHub ID → real name; null if it fails.
    static String resolveRepoName(String base64Id) {
        try {
            String decoded = new String(java.util.Base64.getDecoder().decode(base64Id),
                    java.nio.charset.StandardCharsets.UTF_8);
            int slash = decoded.lastIndexOf('/');
            if (slash >= 0) {
                String numeric = decoded.substring(slash + 1);
                if (numeric.matches("\\d+"))
                    return MdsscApiClient.githubRepoName(numeric);
            }
        } catch (Exception ignored) { /* fallback: no name */ }
        return null;
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
                if (apiKey.isBlank()) return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);

                // If a workflowId is specified, pre-select its connection
                WorkflowInfo wf = workflowInfoQuiet(client, workflowId);
                String selStorage = (wf != null) ? wf.getStorageId() : "";

                var services = client.listServices();
                if (services.isArray()) {
                    for (var s : services) {
                        String id   = textOf(s, "id", "Id");
                        String name = textOf(s, "name", "Name", "serviceName", "ServiceName");
                        String label = name.isBlank() ? id : name + " (" + id + ")";
                        boolean sel = !selStorage.isBlank() && selStorage.equals(id);
                        m.add(new ListBoxModel.Option(label, id, sel));
                    }
                }
            } catch (Exception e) {
                m.add("(error: " + e.getMessage() + ")", "");
            }
            return m;
        }

        public ListBoxModel doFillRepositoryItems(
                @QueryParameter String mdsscInstance,
                @QueryParameter String credentialsId,
                @QueryParameter String connectionId,
                @QueryParameter String workflowId) {
            ListBoxModel m = new ListBoxModel();
            m.add("-- select repository --", "");
            if (connectionId == null || connectionId.isBlank()) return m;
            try {
                String apiKey = resolveKey(credentialsId);
                if (apiKey.isBlank()) return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);

                // Pre-select the workflow's repo if one is specified
                WorkflowInfo wf = workflowInfoQuiet(client, workflowId);
                String selRepo = (wf != null) ? wf.getRepositoryId() : "";

                // MDSSC does not expose friendly names — try the GitHub API, fall back to base64
                var refs = client.listReferences(connectionId);
                if (refs.isArray()) {
                    for (var r : refs) {
                        String id = textOf(r, "repositoryId", "RepositoryId", "id", "Id");
                        boolean sel = !selRepo.isBlank() && selRepo.equals(id);
                        m.add(new ListBoxModel.Option(repoDisplayName(id), id, sel));
                    }
                }
            } catch (Exception e) {
                m.add("(error: " + e.getMessage() + ")", "");
            }
            return m;
        }

        // Fetch workflow info without throwing an exception (UI context).
        private WorkflowInfo workflowInfoQuiet(MdsscApiClient client, String workflowId) {
            if (workflowId == null || workflowId.isBlank()) return null;
            try {
                return client.fetchWorkflowById(workflowId.trim());
            } catch (Exception e) {
                return null;
            }
        }

        // Display name: try the GitHub API (real name), otherwise the decoded base64.
        private String repoDisplayName(String base64Id) {
            String decoded = decodeRepoId(base64Id);   // e.g. "github-ioana/1264280155"
            int slash = decoded.lastIndexOf('/');
            if (slash >= 0) {
                String numeric = decoded.substring(slash + 1);
                if (numeric.matches("\\d+")) {
                    String ghName = MdsscApiClient.githubRepoName(numeric);
                    if (ghName != null && !ghName.isBlank()) return ghName;
                }
            }
            return decoded;
        }

        // base64 "Z2l0aHViLWlvYW5hLzEyNjQyODAxNTU=" → "github-ioana/1264280155"
        private String decodeRepoId(String id) {
            try {
                String decoded = new String(java.util.Base64.getDecoder().decode(id),
                        java.nio.charset.StandardCharsets.UTF_8);
                return decoded.matches("[\\p{Print}]+") ? decoded : id;
            } catch (Exception e) {
                return id;
            }
        }

        public ListBoxModel doFillBranchItems(
                @QueryParameter String mdsscInstance,
                @QueryParameter String credentialsId,
                @QueryParameter String connectionId,
                @QueryParameter String repository,
                @QueryParameter String workflowId) {
            ListBoxModel m = new ListBoxModel();
            m.add("-- select branch --", "");
            if (connectionId == null || connectionId.isBlank()) return m;
            try {
                String apiKey = resolveKey(credentialsId);
                if (apiKey.isBlank()) return m;
                MdsscApiClient client = new MdsscApiClient(mdsscInstance, apiKey);
                boolean autoSelect = workflowId != null && !workflowId.isBlank();
                var refs = client.listReferences(connectionId);
                if (refs.isArray()) {
                    for (var r : refs) {
                        String repoId = textOf(r, "repositoryId", "RepositoryId", "id", "Id");
                        if (!repoId.equals(repository)) continue;
                        String def = textOf(r, "defaultReference", "DefaultReference");
                        JsonNode branches = r.path("references");
                        if (branches.isMissingNode()) branches = r.path("References");
                        if (branches.isArray()) {
                            for (var b : branches) {
                                String name = b.isTextual() ? b.asText()
                                        : textOf(b, "name", "Name", "ref", "Ref");
                                if (name.isBlank()) continue;
                                boolean sel = autoSelect && name.equals(def);
                                m.add(new ListBoxModel.Option(name, name, sel));
                            }
                        }
                        if (!def.isBlank() && m.stream().noneMatch(o -> o.value.equals(def)))
                            m.add(0, new ListBoxModel.Option(def + " (default)", def, autoSelect));
                        break;
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

        @SuppressWarnings("deprecation")
        private String resolveKey(String credId) {
            if (credId == null || credId.isBlank()) return "";
            try {
                return CredentialsProvider.lookupCredentials(
                        StringCredentials.class, Jenkins.get(), ACL.SYSTEM, Collections.emptyList())
                        .stream()
                        .filter(c -> c.getId().equals(credId))
                        .findFirst()
                        .map(c -> c.getSecret().getPlainText())
                        .orElse("");
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