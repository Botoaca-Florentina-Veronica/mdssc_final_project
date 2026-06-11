package io.jenkins.plugins.mdssc.model;

public class WorkflowInfo {
    private final String workflowId;
    private final String storageId;
    private final String repositoryId;
    private final String repositoryName;

    public WorkflowInfo(String workflowId, String storageId,
            String repositoryId, String repositoryName) {
        this.workflowId = workflowId;
        this.storageId = storageId;
        this.repositoryId = repositoryId;
        this.repositoryName = repositoryName;
    }

    public boolean isValid() {
        return workflowId != null && !workflowId.isBlank()
                && storageId != null && !storageId.isBlank()
                && repositoryId != null && !repositoryId.isBlank();
    }

    public String getWorkflowId() {
        return workflowId;
    }

    public String getStorageId() {
        return storageId;
    }

    public String getRepositoryId() {
        return repositoryId;
    }

    public String getRepositoryName() {
        return repositoryName;
    }
}