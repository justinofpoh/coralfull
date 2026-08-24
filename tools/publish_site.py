#!/usr/bin/env python3
"""Publish a finished site to the coralfull backend.

The Metashape + CoralScapes pipeline runs locally and writes a site directory
that only exists on the machine that produced it.  This uploads that directory
so every client can see it:

    metadata + manifest -> Postgres
    artifacts           -> content-addressed blob store

Transfer is one request per file rather than a single archive, so a dropped
connection costs one file instead of the whole ~55 MB, and re-running skips
whatever a previous attempt already stored.

Written against the standard library only: it runs from the pipeline venv, and
from process_site.py, without adding a dependency.

Usage:
    publish_site.py --dir ~/Library/Application\\ Support/coralfull/sites/<uuid> \\
                    --name "Site B" --priority medium

    publish_site.py --manifest macos/coralfull/coralfull/ReefViewer/site_b_sequence.json \\
                    --name "Reef Star Patch #1" --cover covers/site-b.png
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_API = os.environ.get("CORALFULL_API", "http://localhost:8321")

# Where a manifest may live, relative to a site directory.
MANIFEST_CANDIDATES = (
    "analysis/site_sequence.json",
    "site_sequence.json",
    "site_b_sequence.json",
)

# The mesh triple the viewers need.  process_site.py currently leaves
# manifest["mesh"] null and the web app injects these names as SITE_B_FALLBACK
# (web/lib/artifacts.ts).  Filling them in here kills that hack: the manifest
# the backend stores names its own mesh.
MESH_FALLBACK = {
    "ply": "site_b_metashape_mesh.ply",
    "texture": "site_b_metashape_mesh.jpg",
    "vertexLabels": "site_b_semantic_vertex_labels.bin",
}

COVER_REL_PATH = "cover.jpg"


class PublishError(RuntimeError):
    pass


def request(method: str, url: str, *, body: bytes | None = None,
            content_type: str | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        # A server that rejects an upload early closes the connection while we
        # are still writing, and urllib surfaces that as a broken pipe rather
        # than the status it actually sent. Say so, instead of "connection lost".
        if isinstance(e.reason, (BrokenPipeError, ConnectionResetError)):
            raise PublishError(
                f"{method} {url}: connection closed mid-body ({e.reason}); "
                f"the server likely rejected it -- check its log"
            ) from e
        raise PublishError(f"cannot reach {url}: {e.reason}") from e
    except (BrokenPipeError, ConnectionResetError) as e:
        raise PublishError(
            f"{method} {url}: connection closed mid-body ({e}); "
            f"the server likely rejected it -- check its log"
        ) from e


def api_json(method: str, url: str, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    status, raw = request(method, url, body=body,
                          content_type="application/json" if body else None)
    try:
        parsed = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        raise PublishError(f"{method} {url} -> {status}, non-JSON response: {raw[:200]!r}")
    if status >= 400:
        raise PublishError(f"{method} {url} -> {status}: {json.dumps(parsed)}")
    return parsed


def find_manifest(site_dir: Path) -> Path:
    for candidate in MANIFEST_CANDIDATES:
        path = site_dir / candidate
        if path.is_file():
            return path
    raise PublishError(
        f"no manifest under {site_dir}; looked for {', '.join(MANIFEST_CANDIDATES)}")


def fill_mesh(manifest: dict, root: Path) -> dict:
    """Point manifest['mesh'] at real files when the pipeline left it null."""
    mesh = manifest.get("mesh")
    if isinstance(mesh, dict) and mesh.get("ply"):
        return manifest

    found = {k: v for k, v in MESH_FALLBACK.items() if (root / v).is_file()}
    if not found:
        return manifest

    merged = dict(mesh) if isinstance(mesh, dict) else {}
    merged.update(found)
    manifest["mesh"] = merged
    print(f"  filled manifest.mesh from files on disk: {sorted(found)}")
    return manifest


def collect(manifest: dict) -> list[str]:
    """Every site-relative path the manifest references.

    Mirrors referencedPaths in internal/services/site/manifest.go; the backend
    is the authority, this is only used to report what will be sent.
    """
    paths: set[str] = set()
    for frame in manifest.get("frames") or []:
        for key in ("rgb", "semantic", "depth", "mask"):
            if frame.get(key):
                paths.add(frame[key])
    mesh = manifest.get("mesh") or {}
    for key in ("ply", "texture", "vertexLabels"):
        if mesh.get(key):
            paths.add(mesh[key])
    return sorted(paths)


def put_file(api: str, site_id: str, rel_path: str, source: Path,
             attempts: int = 3) -> int:
    """Upload one artifact.

    Retried on its own because that is the point of sending files individually:
    a flaky link costs one file, not the whole publish. Uploads are idempotent
    server-side -- same bytes, same content hash -- so retrying after an
    ambiguous failure is always safe.
    """
    ctype = mimetypes.guess_type(rel_path)[0] or "application/octet-stream"
    data = source.read_bytes()
    url = f"{api}/api/sites/{site_id}/files/{rel_path}"

    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            status, raw = request("PUT", url, body=data, content_type=ctype)
        except PublishError as e:
            last = e
        else:
            if status < 400:
                return len(data)
            if status < 500:
                # 4xx is our fault and will not improve on a retry.
                raise PublishError(f"PUT {rel_path} -> {status}: {raw[:300]!r}")
            last = PublishError(f"PUT {rel_path} -> {status}: {raw[:300]!r}")
        if attempt < attempts:
            print(f"  retrying {rel_path} ({attempt}/{attempts - 1}): {last}")
    raise last  # type: ignore[misc]


def ensure_site(api: str, site_id: str | None, payload: dict) -> tuple[str, list[str]]:
    """Return the id of the site to upload into, plus what it still needs.

    When the caller already has an id -- the usual case, because the web app
    creates the row before the pipeline starts, so an in-progress scan is
    visible -- the manifest is patched onto that record. Creating a second row
    here would put the same scan in the list twice.
    """
    if site_id:
        status, _ = request("GET", f"{api}/api/sites/{site_id}")
        if status == 200:
            patch = {k: v for k, v in payload.items() if k != "state"}
            api_json("PATCH", f"{api}/api/sites/{site_id}", patch)
            missing = api_json("GET", f"{api}/api/sites/{site_id}/missing")["data"]["missing"]
            print(f"updating existing site {site_id} ({len(missing)} files to upload)")
            return site_id, missing
        if status != 404:
            raise PublishError(f"GET /api/sites/{site_id} -> {status}")

    created = api_json("POST", f"{api}/api/sites", payload)["data"]
    new_id = created["site"]["id"]
    print(f"created site {new_id} ({len(created['missing'])} files to upload)")
    return new_id, created["missing"]


def publish(args) -> str:
    api = args.api.rstrip("/")

    if args.manifest:
        manifest_path = Path(args.manifest).expanduser().resolve()
        site_dir = manifest_path.parent
    else:
        site_dir = Path(args.dir).expanduser().resolve()
        manifest_path = find_manifest(site_dir)

    # Manifest paths are relative to the manifest's own directory -- the same
    # rule web/lib/artifacts.ts analysisRoot() applies.
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text())
    manifest = fill_mesh(manifest, root)

    referenced = collect(manifest)
    print(f"manifest: {manifest_path}")
    print(f"  {len(manifest.get('frames') or [])} frames, {len(referenced)} referenced files")

    cover_source = None
    if args.cover:
        cover_source = Path(args.cover).expanduser().resolve()
    elif (site_dir / "cover.jpg").is_file():
        cover_source = site_dir / "cover.jpg"

    # Resolve every source file before creating anything server-side. Without
    # this a missing file aborts mid-upload and leaves an orphan site row stuck
    # in "importing" that someone has to go and delete.
    sources: dict[str, Path] = {}
    for rel in referenced:
        source = root / rel
        if not source.is_file():
            raise PublishError(f"manifest references {rel!r}, but {source} does not exist")
        sources[rel] = source
    if cover_source:
        if not cover_source.is_file():
            raise PublishError(f"cover {cover_source} does not exist")
        sources[COVER_REL_PATH] = cover_source

    payload = {
        "name": args.name,
        "priority": args.priority,
        "photoCount": args.photo_count
        if args.photo_count is not None
        else len(manifest.get("frames") or []),
        "tags": args.tags,
        "manifest": manifest,
    }
    if cover_source:
        payload["coverPath"] = COVER_REL_PATH
    if args.state:
        payload["state"] = {args.state: {}}

    site_id, missing = ensure_site(api, getattr(args, "site_id", None), payload)

    sent = total_bytes = 0
    skipped = len(sources) - len(missing)
    for rel in missing:
        source = sources.get(rel)
        if source is None:
            raise PublishError(
                f"backend wants {rel!r}, which is not in the manifest or the cover")
        total_bytes += put_file(api, site_id, rel, source)
        sent += 1
        if sent % 25 == 0 or sent == len(missing):
            print(f"  uploaded {sent}/{len(missing)} ({total_bytes / 1e6:.1f} MB)")

    still_missing = api_json("GET", f"{api}/api/sites/{site_id}/missing")["data"]["missing"]
    if still_missing:
        raise PublishError(
            f"{len(still_missing)} files still missing after upload: {still_missing[:3]}")

    result = api_json("POST", f"{api}/api/sites/{site_id}/publish")["data"]
    print(f"published: state={result['state']}"
          + (f" ({skipped} already stored)" if skipped else ""))
    print(f"  {api}/api/sites/{site_id}")
    return site_id


def publish_site(*, site_dir, site_name: str, site_id: str | None = None,
                 api: str = DEFAULT_API, priority: str = "medium",
                 tags=(), cover=None, photo_count: int | None = None) -> str:
    """Publish a finished site directory. Raises PublishError on failure."""
    return publish(argparse.Namespace(
        dir=str(site_dir), manifest=None, name=site_name, site_id=site_id,
        priority=priority, photo_count=photo_count, tags=list(tags),
        cover=str(cover) if cover else None, state=None, api=api,
    ))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--site-id", default=None,
                   help="upload into this existing site instead of creating one")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--dir", help="site directory containing the manifest")
    source.add_argument("--manifest", help="path to the manifest itself")
    p.add_argument("--name", required=True, help="display name")
    p.add_argument("--priority", default="medium", choices=("high", "medium", "low"))
    p.add_argument("--photo-count", type=int, default=None,
                   help="defaults to the manifest frame count")
    p.add_argument("--tags", nargs="*", default=[])
    p.add_argument("--cover", default=None,
                   help="cover image; defaults to <dir>/cover.jpg when present")
    p.add_argument("--state", default=None,
                   choices=("importing", "processing", "ready", "failed",
                            "cancelled", "interrupted"),
                   help="initial state; publish sets it to ready on success")
    p.add_argument("--api", default=DEFAULT_API, help=f"backend base URL (default {DEFAULT_API})")

    args = p.parse_args()
    try:
        publish(args)
    except PublishError as e:
        print(f"publish failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
