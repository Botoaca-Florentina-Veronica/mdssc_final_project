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

    // După ScanningState=Completed, analiza pachetelor (SBOM → vulnerabilități)
    // poate continua câteva secunde. Așteptăm până apar rezultatele reale.
    private static final long ANALYSIS_GRACE_MS = 90_000;

    public ScanResult pollUntilDone(String scanId, String label, PrintStream log)
            throws Exception {
        long start = System.currentTimeMillis();
        long timeout = (long) timeoutSeconds * 1000;
        long doneSince = -1;

        log.printf("[MDSSC] Polling scan %s (%s)...%n", scanId, label);

        ScanResult result = null;
        while (System.currentTimeMillis() - start < timeout) {
            result = client.pollOverview(scanId, log);
            long elapsed = (System.currentTimeMillis() - start) / 1000;

            log.printf("[MDSSC] [%ds] %s | %s (%s%%) | C:%d H:%d M:%d L:%d | Pkg:%d/%d | Malware:%d Secrets:%d%n",
                    elapsed, label,
                    result.getState(), result.getProgress(),
                    result.getCritical(), result.getHigh(),
                    result.getMedium(), result.getLow(),
                    result.getVulnerablePackages(), result.getTotalPackages(),
                    result.getMalware(), result.getSecrets());

            if (result.isError())
                throw new Exception("[MDSSC] Scan failed: " + result.getState());

            if (result.isDone()) {
                // Rezultate populate → gata.
                if (result.hasResults())
                    return result;
                // Completat dar analiza pachetelor încă rulează → așteptăm grace period.
                long now = System.currentTimeMillis();
                if (doneSince < 0) {
                    doneSince = now;
                    log.println("[MDSSC] Scan complet — aștept finalizarea analizei pachetelor...");
                } else if (now - doneSince >= ANALYSIS_GRACE_MS) {
                    log.println("[MDSSC] Analiză finalizată — nicio vulnerabilitate detectată.");
                    return result;
                }
            }

            Thread.sleep(pollIntervalSeconds * 1000L);
        }
        // Timeout: dacă scanul e cel puțin Completed, întoarce ce avem.
        if (result != null && result.isDone())
            return result;
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