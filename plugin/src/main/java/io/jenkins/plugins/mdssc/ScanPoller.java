package io.jenkins.plugins.mdssc;

import io.jenkins.plugins.mdssc.model.ScanResult;
import io.jenkins.plugins.mdssc.model.VulnerabilityThreshold;

import java.io.PrintStream;

public class ScanPoller {

    private final MdsscApiClient client;
    private final int timeoutSeconds;
    private final int pollIntervalSeconds;

    public ScanPoller(MdsscApiClient client, int timeoutSeconds, int pollIntervalSeconds) {
        this.client = client;
        this.timeoutSeconds = timeoutSeconds;
        this.pollIntervalSeconds = pollIntervalSeconds;
    }

    public ScanResult pollUntilDone(String scanId, String label, PrintStream log)
            throws Exception {
        long start = System.currentTimeMillis();
        long timeout = (long) timeoutSeconds * 1000;

        log.printf("[MDSSC] Polling scan %s (%s)...%n", scanId, label);

        while (System.currentTimeMillis() - start < timeout) {
            ScanResult result = client.pollOverview(scanId, log);
            long elapsed = (System.currentTimeMillis() - start) / 1000;

            log.printf("[MDSSC] [%ds] %s | %s (%s%%) | C:%d H:%d M:%d L:%d | Malware:%d Secrets:%d%n",
                    elapsed, label,
                    result.getState(), result.getProgress(),
                    result.getCritical(), result.getHigh(),
                    result.getMedium(), result.getLow(),
                    result.getMalware(), result.getSecrets());

            if (result.isDone())
                return result;
            if (result.isError())
                throw new Exception("[MDSSC] Scan failed: " + result.getState());

            Thread.sleep(pollIntervalSeconds * 1000L);
        }
        throw new Exception("[MDSSC] Scan timed out after " + timeoutSeconds + "s");
    }

    public void evaluateAndFail(ScanResult result, String label,
            VulnerabilityThreshold threshold,
            boolean failOnSecret, boolean failOnMalware,
            PrintStream log) throws Exception {
        log.println("");
        log.println("==========================================");
        log.println("   MDSSC SCAN REPORT — " + label);
        log.println("==========================================");
        log.printf("  Final state      : %s%n", result.getState());
        log.println("------------------------------------------");
        log.println("  VULNERABILITIES:");
        log.printf("  Critical         : %d%n", result.getCritical());
        log.printf("  High             : %d%n", result.getHigh());
        log.printf("  Medium           : %d%n", result.getMedium());
        log.printf("  Low              : %d%n", result.getLow());
        log.println("------------------------------------------");
        log.println("  OTHER FINDINGS:");
        log.printf("  Malware          : %d%n", result.getMalware());
        log.printf("  Secrets          : %d%n", result.getSecrets());
        log.printf("  Blocked Licenses : %d%n", result.getBlockedLicenses());
        log.println("==========================================");

        if (failOnSecret && result.getSecrets() > 0) {
            throw new Exception(String.format(
                    "[MDSSC] FAIL: %d secret(s) detected in '%s'", result.getSecrets(), label));
        }

        if (failOnMalware && result.getMalware() > 0) {
            throw new Exception(String.format(
                    "[MDSSC] FAIL: %d malware item(s) detected in '%s'", result.getMalware(), label));
        }

        if (threshold != VulnerabilityThreshold.NONE) {
            boolean fails = threshold.isMet(
                    result.getCritical(), result.getHigh(),
                    result.getMedium(), result.getLow());
            if (fails) {
                throw new Exception(String.format(
                        "[MDSSC] FAIL: Vulnerabilities at or above '%s' threshold in '%s'",
                        threshold.name().toLowerCase(), label));
            }
        }

        log.println("[MDSSC] Scan passed all thresholds.");
    }
}