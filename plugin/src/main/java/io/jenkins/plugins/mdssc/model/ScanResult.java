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
        r.state = extractState(data);
        r.progress = textOf(data, "ScanProgress", "scanProgress", "progress");

        // MDSSC API structure: ScanInformation.VulnerabilityIssues.{critical,high,medium,low}
        JsonNode scanInfo = firstOf(data, "ScanInformation", "scanInformation");
        JsonNode vulnNode = null;
        if (scanInfo != null) {
            vulnNode = firstOf(scanInfo, "VulnerabilityIssues", "vulnerabilityIssues");
        }
        // Fallback: VulnerabilityIssues at root level
        if (vulnNode == null) {
            vulnNode = firstOf(data, "VulnerabilityIssues", "vulnerabilityIssues",
                    "vulnerabilityStatus", "VulnerabilityStatus",
                    "vulnerabilities", "Vulnerabilities");
        }
        JsonNode src = (vulnNode != null) ? vulnNode : data;

        r.critical = intOf(src, "critical", "Critical");
        r.high     = intOf(src, "high",     "High");
        r.medium   = intOf(src, "medium",   "Medium", "moderate", "Moderate");
        r.low      = intOf(src, "low",      "Low");

        // Malware / Secret are booleans in ScanInformation
        if (scanInfo != null) {
            r.malware = boolOf(scanInfo, "Malware", "malware") ? 1 : 0;
            r.secrets = boolOf(scanInfo, "Secret",  "secret", "Secrets", "secrets") ? 1 : 0;
            JsonNode lic = firstOf(scanInfo, "Licenses", "licenses");
            if (lic != null)
                r.blockedLicenses = intOf(lic, "BlockedLicensesCount", "blockedLicensesCount");
        } else {
            r.malware         = intOf(data, "Malware", "malware");
            r.secrets         = intOf(data, "Secret",  "secret", "Secrets", "secrets");
            r.blockedLicenses = intOf(data, "BlockedLicensesCount", "blockedLicensesCount");
        }
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

    // Identical to Jenkins mdsscAdvanced.groovy — also looks inside the nested scanStatus object
    private static String extractState(JsonNode data) {
        // 1. Top-level fields
        for (String k : new String[]{"ScanningState", "scanningState"}) {
            if (data != null && data.has(k) && data.get(k).isTextual())
                return data.get(k).asText();
        }
        // 2. Nested object: scanStatus.scanningState / ScanStatus.ScanningState
        for (String outer : new String[]{"scanStatus", "ScanStatus"}) {
            JsonNode ss = data != null ? data.path(outer) : null;
            if (ss != null && !ss.isMissingNode() && ss.isObject()) {
                for (String inner : new String[]{"scanningState", "ScanningState"}) {
                    if (ss.has(inner) && ss.get(inner).isTextual())
                        return ss.get(inner).asText();
                }
            }
        }
        // 3. Generic fallback
        for (String k : new String[]{"status", "Status", "state", "State"}) {
            if (data != null && data.has(k) && data.get(k).isTextual())
                return data.get(k).asText();
        }
        return null;
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

    private static boolean boolOf(JsonNode n, String... keys) {
        for (String k : keys)
            if (n != null && n.has(k) && !n.get(k).isNull())
                return n.get(k).asBoolean(false);
        return false;
    }

    private static JsonNode firstOf(JsonNode n, String... keys) {
        for (String k : keys)
            if (n != null && n.has(k))
                return n.get(k);
        return null;
    }
}