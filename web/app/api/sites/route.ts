import { NextResponse } from "next/server";
import { createSiteRecord } from "@/lib/sites";

export const runtime = "nodejs";

/**
 * Creates the local working directory for a scan.
 *
 * Listing sites is no longer served from here -- the Go backend owns the site
 * list, the analysis manifests and every artifact. What remains local is the
 * pipeline: photos are copied here, Metashape and CoralScapes run here, and the
 * finished output is published to the backend by tools/publish_site.py.
 */
export async function POST(request: Request) {
  const body = (await request.json()) as { name?: string; id?: string };
  const name = (body.name ?? "").trim();
  if (!name) {
    return NextResponse.json({ error: "Enter a site name." }, { status: 400 });
  }
  // The backend has already created the record and assigned the id.
  const site = body.id ? createSiteRecord(name, body.id) : createSiteRecord(name);
  return NextResponse.json({ site });
}
