package io.jenkins.plugins.mdssc.model;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Set;
import java.util.HashSet;
import java.util.Arrays;

public class ScanResult {
    private String state;
    private String progress;
    private int critical, high, medium, low;
    private int malware, secrets, blockedLicenses;

    private static final Set<String> DONE_STATES = new HashSet<>(Arrays.asList(
            "completed", "complete", "finished", "done", "success"));
    private static final Set<String> ERROR_STATES = new HashSet<>(Arrays.asList(
            "failed", "failure", "error", "cancelled", "canceled"));

    public static ScanResult fromJson(JsonNode data) {
        ScanResult r = new ScanResult();
        r.state = textOf(data, "ScanningState", "scanningState", "status", "Status", "state");
        r.progress = textOf(data, "ScanProgress", "scanProgress", "progress");

        JsonNode iss = firstOf(data, "vulnerabilityIssues", "VulnerabilityIssues");
        JsonNode src = (iss != null) ? iss : data;
        r.critical = intOf(src, "critical", "Critical");
        r.high = intOf(src, "high", "High");
        r.medium = intOf(src, "medium", "Medium", "moderate", "Moderate");
        r.low = intOf(src, "low", "Low");

        r.malware = intOf(data, "Malware", "malware");
        r.secrets = intOf(data, "Secret", "secret", "Secrets", "secrets");
        r.blockedLicenses = intOf(data, "BlockedLicensesCount", "blockedLicensesCount");
        return r;
    }

    public boolean isDone() {
        return state != null && DONE_STATES.contains(state.toLowerCase());
    }

    public boolean isError() {
        return state != null && ERROR_STATES.contains(state.toLowerCase());
    }

    public String getState() {
        return state != null ? state : "Unknown";
    }

    public String getProgress() {
        return progress != null ? progress : "?";
    }

    public int getCritical() {
        return critical;
    }

    public int getHigh() {
        return high;
    }

    public int getMedium() {
        return medium;
    }

    public int getLow() {
        return low;
    }

    public int getMalware() {
        return malware;
    }

    public int getSecrets() {
        return secrets;
    }

    public int getBlockedLicenses() {
        return blockedLicenses;
    }

    private static String textOf(JsonNode n, String... keys) {
        for (String k : keys)
            if (n != null && n.has(k) && n.get(k).isTextual())
                return n.get(k).asText();
        return "Unknown";
    }

    private static int intOf(JsonNode n, String... keys) {
        for (String k : keys)
            if (n != null && n.has(k) && !n.get(k).isNull())
                return n.get(k).asInt(0);
        return 0;
    }

    private static JsonNode firstOf(JsonNode n, String... keys) {
        for (String k : keys)
            if (n != null && n.has(k))
                return n.get(k);
        return null;
    }
}