package io.jenkins.plugins.mdssc;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.jenkins.plugins.mdssc.model.ScanResult;
import io.jenkins.plugins.mdssc.model.WorkflowInfo;

import java.io.*;
import java.net.*;
import java.nio.file.Files;

public class MdsscApiClient {

    private final String baseUrl;
    private final String apiKey;
    private final String apiKeyHeader;
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public MdsscApiClient(String serverUrl, String apiKey) {
        this(serverUrl, apiKey, "apikey");
    }

    public MdsscApiClient(String serverUrl, String apiKey, String apiKeyHeader) {
        String s = serverUrl.replaceAll("/+$", "");
        this.baseUrl = s.endsWith("/api/v1") ? s : s + "/api/v1";
        this.apiKey = apiKey;
        this.apiKeyHeader = apiKeyHeader;
    }

    public boolean checkHealth(PrintStream log) {
        String[] paths = { "/health", "/version", "/scans?limit=1" };
        for (String path : paths) {
            try {
                HttpURLConnection conn = openGet(baseUrl + path);
                int code = conn.getResponseCode();
                log.printf("[MDSSC] GET %s → HTTP %d%n", path, code);
                if (code >= 200 && code < 300) {
                    log.println("[MDSSC] Health check OK");
                    return true;
                }
            } catch (Exception e) {
                log.printf("[MDSSC] Health probe %s failed: %s%n", path, e.getMessage());
            }
        }
        log.println("[MDSSC] WARNING: Could not confirm server health — continuing.");
        return false;
    }

    public WorkflowInfo resolveWorkflow(String workflowId, PrintStream log) throws Exception {
        if (workflowId != null && !workflowId.isBlank()) {
            return fetchWorkflowById(workflowId, log);
        }
        log.println("[MDSSC] No workflowId — auto-detecting default workflow...");
        HttpURLConnection conn = openGet(baseUrl + "/workflows");
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) {
            log.printf("[MDSSC] WARNING: GET /workflows → HTTP %d%n", code);
            return new WorkflowInfo("", "", "", "");
        }
        JsonNode root = MAPPER.readTree(readBody(conn));
        JsonNode list = root.isArray() ? root
                : firstNonNull(root, "workflows", "Workflows", "data", "Data");
        if (list == null || !list.isArray() || list.size() == 0) {
            log.println("[MDSSC] WARNING: No workflows found.");
            return new WorkflowInfo("", "", "", "");
        }
        JsonNode first = list.get(0);
        String id = textOf(first, "id", "Id", "workflowId", "WorkflowId");
        log.printf("[MDSSC] Auto-selected workflow: %s%n", id);
        return fetchWorkflowById(id, log);
    }

    // Silent overload for the UI context (descriptor) — no log.
    public WorkflowInfo fetchWorkflowById(String workflowId) throws Exception {
        return fetchWorkflowById(workflowId, new PrintStream(OutputStream.nullOutputStream()));
    }

    public WorkflowInfo fetchWorkflowById(String workflowId, PrintStream log) throws Exception {
        HttpURLConnection conn = openGet(baseUrl + "/workflows/" + workflowId);
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) {
            log.printf("[MDSSC] WARNING: GET /workflows/%s → HTTP %d%n", workflowId, code);
            return new WorkflowInfo(workflowId, "", "", "");
        }
        JsonNode data = MAPPER.readTree(readBody(conn));
        JsonNode sources = firstNonNull(data, "ScanSources", "scanSources");
        JsonNode firstSrc = (sources != null && sources.isArray() && sources.size() > 0)
                ? sources.get(0)
                : MAPPER.createObjectNode();
        String storageId = textOf(firstSrc, "ServiceId", "serviceId");
        JsonNode repos = firstNonNull(firstSrc, "Repositories", "repositories");
        JsonNode firstRepo = (repos != null && repos.isArray() && repos.size() > 0)
                ? repos.get(0)
                : MAPPER.createObjectNode();
        String repoId = textOf(firstRepo, "RepositoryId", "repositoryId", "Id", "id");
        String repoName = textOf(firstRepo, "RepositoryName", "repositoryName", "Name", "name");
        log.printf("[MDSSC] Workflow %s | storageId=%s | repoId=%s%n",
                workflowId, storageId, repoId);
        return new WorkflowInfo(workflowId, storageId, repoId, repoName);
    }

    // GET /api/v1/services — list of connections (GitHub, etc.)
    // The response can be a plain array OR {"serviceDtos":[...]} / {"data":[...]}
    public JsonNode listServices() throws Exception {
        HttpURLConnection conn = openGet(baseUrl + "/services");
        int code = conn.getResponseCode();
        if (code >= 300)
            throw new IOException("GET /services → HTTP " + code + " — " + readBody(conn));
        JsonNode root = MAPPER.readTree(readBody(conn));
        return unwrapArray(root, "serviceDtos", "ServiceDtos", "services", "Services", "data", "Data");
    }

    // GET /api/v1/services/{storageId}/references — repositories + branches
    // The response can be a plain array OR {"repositoryReferenceInfoArray":[...]}
    public JsonNode listReferences(String storageId) throws Exception {
        if (storageId == null || storageId.isBlank()) return MAPPER.createArrayNode();
        HttpURLConnection conn = openGet(baseUrl + "/services/" + storageId + "/references");
        int code = conn.getResponseCode();
        if (code >= 300)
            throw new IOException("GET /services/" + storageId + "/references → HTTP "
                    + code + " — " + readBody(conn));
        JsonNode root = MAPPER.readTree(readBody(conn));
        return unwrapArray(root, "repositoryReferenceInfoArray", "RepositoryReferenceInfoArray",
                "references", "References", "data", "Data");
    }

    // GET https://api.github.com/repositories/{numericId} → the repository name.
    // Unauthenticated (limit 60/hour). Returns null on any failure (rate limit, etc.).
    public static String githubRepoName(String numericId) {
        try {
            HttpURLConnection c = (HttpURLConnection)
                    new URL("https://api.github.com/repositories/" + numericId).openConnection();
            c.setRequestMethod("GET");
            c.setRequestProperty("Accept", "application/vnd.github+json");
            c.setRequestProperty("User-Agent", "mdssc-jenkins-plugin");
            c.setConnectTimeout(3000);
            c.setReadTimeout(3000);
            if (c.getResponseCode() != 200) return null;
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(c.getInputStream(), "UTF-8"))) {
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = r.readLine()) != null) sb.append(line);
                JsonNode n = MAPPER.readTree(sb.toString());
                if (n.has("name")) return n.get("name").asText();
                if (n.has("full_name")) return n.get("full_name").asText();
            }
        } catch (Exception ignored) { /* fall back to the decoded base64 */ }
        return null;
    }

    // If root is already an array → return it; otherwise find the first field that is an array.
    private JsonNode unwrapArray(JsonNode root, String... keys) {
        if (root != null && root.isArray()) return root;
        JsonNode inner = firstNonNull(root, keys);
        if (inner != null && inner.isArray()) return inner;
        return MAPPER.createArrayNode();
    }

    public String scanFileDirect(File file, String fileName, String workflowId, PrintStream log)
            throws Exception {
        // The name shown in the report (without the temp file prefix)
        String displayName = (fileName != null && !fileName.isBlank()) ? fileName : file.getName();
        log.printf("[MDSSC] Uploading artifact: %s (%d KB)%n",
                displayName, file.length() / 1024);
        String boundary = "----MdsscBoundary" + System.currentTimeMillis();
        HttpURLConnection conn = (HttpURLConnection) new URL(baseUrl + "/scans/direct").openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty(apiKeyHeader, apiKey);
        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
        conn.setDoOutput(true);
        conn.setConnectTimeout(15_000);
        conn.setReadTimeout(300_000);

        try (OutputStream os = conn.getOutputStream();
                PrintWriter pw = new PrintWriter(new OutputStreamWriter(os, "UTF-8"), true)) {
            if (workflowId != null && !workflowId.isBlank()) {
                pw.printf("--%s\r\nContent-Disposition: form-data; name=\"workflowId\"\r\n\r\n%s\r\n",
                        boundary, workflowId);
            }
            pw.printf("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n" +
                    "Content-Type: application/octet-stream\r\n\r\n", boundary, displayName);
            pw.flush();
            Files.copy(file.toPath(), os);
            os.flush();
            pw.printf("\r\n--%s--\r\n", boundary);
        }

        int code = conn.getResponseCode();
        String body = readBody(conn);
        log.printf("[MDSSC] POST /scans/direct → HTTP %d%n", code);
        if (code < 200 || code >= 300)
            throw new IOException("[MDSSC] Direct upload failed: HTTP " + code + " — " + body);
        return extractScanId(MAPPER.readTree(body), log);
    }

    public String scanRepositoryIndirect(String storageId, String repositoryId,
            String repositoryName, String workflowId, String branch, PrintStream log) throws Exception {
        log.printf("[MDSSC] Indirect scan — storageId: %s | repoId: %s | branch: %s | wf: %s%n",
                storageId, repositoryId, branch,
                (workflowId == null || workflowId.isBlank()) ? "<default>" : workflowId);

        com.fasterxml.jackson.databind.node.ObjectNode payload = MAPPER.createObjectNode();
        payload.put("storageId", storageId);
        payload.put("repositoryId", repositoryId);
        payload.putArray("repositoryReferences").add(branch);
        payload.put("scanType", 0);
        // Friendly name for the report title (resolved from GitHub)
        if (repositoryName != null && !repositoryName.isBlank())
            payload.put("repositoryName", repositoryName);
        // workflowId is included ONLY if specified — empty/missing = default workflow
        if (workflowId != null && !workflowId.isBlank())
            payload.put("workflowId", workflowId);

        String body = MAPPER.writeValueAsString(payload);
        HttpURLConnection conn = openPost(baseUrl + "/scans", body);
        int code = conn.getResponseCode();
        String resp = readBody(conn);
        log.printf("[MDSSC] POST /scans → HTTP %d%n", code);
        if (code < 200 || code >= 300) {
            log.println("[MDSSC] WARNING: Indirect scan failed: " + resp);
            return null;
        }
        return extractScanId(MAPPER.readTree(resp), log);
    }

    private boolean firstPoll = true;

    public ScanResult pollOverview(String scanId, PrintStream log) throws Exception {
        HttpURLConnection conn = openGet(baseUrl + "/scans/" + scanId + "/overview");
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300)
            conn = openGet(baseUrl + "/scans/" + scanId);
        code = conn.getResponseCode();
        if (code < 200 || code >= 300)
            throw new IOException("[MDSSC] Poll failed HTTP " + code);
        String body = readBody(conn);
        ScanResult result = ScanResult.fromJson(MAPPER.readTree(body));
        if (firstPoll || result.isDone()) {
            log.printf("[MDSSC] DEBUG overview JSON: %s%n",
                    body.length() > 2000 ? body.substring(0, 2000) + "..." : body);
            firstPoll = false;
        }
        return result;
    }

    public ScanResult fetchFullResult(String scanId, PrintStream log) throws Exception {
        HttpURLConnection conn = openGet(baseUrl + "/scans/" + scanId);
        return ScanResult.fromJson(MAPPER.readTree(readBody(conn)));
    }

    private HttpURLConnection openGet(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setRequestMethod("GET");
        c.setRequestProperty(apiKeyHeader, apiKey);
        c.setRequestProperty("Content-Type", "application/json");
        c.setConnectTimeout(15_000);
        c.setReadTimeout(30_000);
        return c;
    }

    private HttpURLConnection openPost(String url, String jsonBody) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setRequestMethod("POST");
        c.setRequestProperty(apiKeyHeader, apiKey);
        c.setRequestProperty("Content-Type", "application/json");
        c.setDoOutput(true);
        c.setConnectTimeout(15_000);
        c.setReadTimeout(60_000);
        try (OutputStream os = c.getOutputStream()) {
            os.write(jsonBody.getBytes("UTF-8"));
        }
        return c;
    }

    private String readBody(HttpURLConnection c) throws Exception {
        InputStream is = c.getResponseCode() < 400 ? c.getInputStream() : c.getErrorStream();
        if (is == null)
            return "";
        try (BufferedReader r = new BufferedReader(new InputStreamReader(is, "UTF-8"))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null)
                sb.append(line).append('\n');
            return sb.toString();
        }
    }

    private String extractScanId(JsonNode data, PrintStream log) {
        JsonNode ids = firstNonNull(data, "scanIds", "ScanIds", "ScanIDs", "scanIDs");
        if (ids != null && ids.isArray() && ids.size() > 0)
            return ids.get(0).asText();
        String id = textOf(data, "scanId", "ScanId", "id", "Id");
        if (id != null && !id.isBlank())
            return id;
        log.println("[MDSSC] WARNING: No scan ID in response: " + data);
        return null;
    }

    private JsonNode firstNonNull(JsonNode node, String... keys) {
        for (String k : keys)
            if (node != null && node.has(k) && !node.get(k).isNull())
                return node.get(k);
        return null;
    }

    private String textOf(JsonNode node, String... keys) {
        JsonNode n = firstNonNull(node, keys);
        return (n != null && n.isTextual()) ? n.asText() : "";
    }
}