import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function hasOrchestrator(root: string) {
  return fs.existsSync(path.join(root, "tools", "process_site.py"));
}

export function repoRoot() {
  const env = process.env.CORALFULL_ROOT;
  const candidates = [
    env,
    process.cwd(),
    path.resolve(process.cwd(), ".."),
    path.join(os.homedir(), "Desktop", "coralfull"),
  ].filter((value): value is string => Boolean(value));

  for (const candidate of candidates) {
    if (hasOrchestrator(candidate)) return path.resolve(candidate);
  }
  return path.resolve(process.cwd(), "..");
}

export function sitesRoot() {
  if (process.env.CORALFULL_SITES_DIR) {
    return path.resolve(process.env.CORALFULL_SITES_DIR);
  }
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "coralfull",
    "sites"
  );
}

export function siteDirectory(siteId: string) {
  return path.join(sitesRoot(), siteId);
}

export function siteBRoot() {
  return path.join(
    repoRoot(),
    "macos",
    "coralfull",
    "coralfull",
    "ReefViewer"
  );
}

export function pythonBin() {
  return path.join(repoRoot(), "tools", "reef_segment", ".venv", "bin", "python");
}

export function orchestratorPath() {
  return path.join(repoRoot(), "tools", "process_site.py");
}

export function metashapeApp() {
  return "/Applications/MetashapePro.app";
}

export function pipelineIssues() {
  const issues: string[] = [];
  if (!fs.existsSync(orchestratorPath())) {
    issues.push(
      `Processing tools not found at ${repoRoot()}. Set CORALFULL_ROOT to the coralfull repository.`
    );
  } else if (!fs.existsSync(pythonBin())) {
    issues.push(
      `The analysis Python environment is missing (${pythonBin()}). Create the venv described in tools/reef_segment/requirements.txt.`
    );
  }
  if (!fs.existsSync(metashapeApp())) {
    issues.push(
      "Agisoft Metashape Pro is not installed at /Applications/MetashapePro.app. Reconstruction requires an activated Metashape Pro."
    );
  }
  return issues;
}

export function ensureDir(directory: string) {
  fs.mkdirSync(directory, { recursive: true });
}
