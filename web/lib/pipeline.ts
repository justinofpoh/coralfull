import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { orchestratorPath, pipelineIssues, pythonBin, repoRoot, siteDirectory } from "./paths";
import { markReady, readSite, readStatus, updateSite } from "./sites";

function pidFile(siteId: string) {
  return path.join(siteDirectory(siteId), "pipeline.pid");
}

export function runningPid(siteId: string) {
  const file = pidFile(siteId);
  if (!fs.existsSync(file)) return null;
  const pid = Number(fs.readFileSync(file, "utf8").trim());
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    fs.rmSync(file, { force: true });
    return null;
  }
}

export function startProcessing(siteId: string) {
  const site = readSite(siteId);
  if (!site) throw new Error("Site not found.");
  const issues = pipelineIssues();
  if (issues.length > 0) {
    updateSite(siteId, { state: { kind: "failed", message: issues.join("\n") } });
    return { started: false, issues };
  }
  if (runningPid(siteId)) {
    updateSite(siteId, { state: { kind: "processing" } });
    return { started: true, issues: [] };
  }

  const directory = siteDirectory(siteId);
  const logPath = path.join(directory, "pipeline.log");
  const log = fs.openSync(logPath, "a");
  const args = [
    orchestratorPath(),
    "--site-dir",
    directory,
    "--site-id",
    siteId,
    "--site-name",
    site.name,
  ];
  if (process.env.CORAL_PIPELINE_FAST === "1") {
    args.push("--match-downscale", "4", "--depth-downscale", "8", "--texture-size", "2048");
  }

  const child = spawn(pythonBin(), args, {
    cwd: repoRoot(),
    env: {
      ...process.env,
      PYTHONUNBUFFERED: "1",
      CORALFULL_ROOT: repoRoot(),
    },
    detached: true,
    stdio: ["ignore", log, log],
  });
  fs.writeFileSync(pidFile(siteId), String(child.pid ?? ""));
  updateSite(siteId, { state: { kind: "processing" } });

  child.on("error", (error) => {
    try {
      fs.closeSync(log);
    } catch {
      // already closed
    }
    fs.rmSync(pidFile(siteId), { force: true });
    updateSite(siteId, {
      state: {
        kind: "failed",
        message: `Could not launch the processing pipeline: ${error.message}`,
      },
    });
  });
  child.on("exit", (code) => {
    try {
      fs.closeSync(log);
    } catch {
      // already closed
    }
    fs.rmSync(pidFile(siteId), { force: true });
    const status = readStatus(siteId);
    if (status?.state === "ready") {
      markReady(siteId);
    } else if (status?.state === "cancelled") {
      updateSite(siteId, { state: { kind: "cancelled" } });
    } else if (status?.state === "failed") {
      updateSite(siteId, {
        state: { kind: "failed", message: status.error || "Processing failed." },
      });
    } else {
      updateSite(siteId, {
        state: {
          kind: "failed",
          message: `The processing pipeline exited unexpectedly (code ${code ?? "unknown"}). See pipeline.log in the site folder.`,
        },
      });
    }
  });
  child.unref();
  return { started: true, issues: [] };
}

export function cancelProcessing(siteId: string) {
  const pid = runningPid(siteId);
  if (pid) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
}

export function retryProcessing(siteId: string) {
  updateSite(siteId, { state: { kind: "processing" } });
  return startProcessing(siteId);
}
