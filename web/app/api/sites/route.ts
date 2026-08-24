import { NextResponse } from "next/server";
import { listSites, readStatus, createSiteRecord } from "@/lib/sites";
import { pipelineIssues } from "@/lib/paths";

export const runtime = "nodejs";

export async function GET() {
  const sites = listSites().map((site) => ({
    ...site,
    status: readStatus(site.id),
    coverUrl: `/api/sites/${site.id}/cover`,
  }));
  return NextResponse.json({
    sites,
    environment: { issues: pipelineIssues() },
  });
}

export async function POST(request: Request) {
  const body = (await request.json()) as { name?: string };
  const name = (body.name ?? "").trim();
  if (!name) {
    return NextResponse.json({ error: "Enter a site name." }, { status: 400 });
  }
  const site = createSiteRecord(name);
  return NextResponse.json({ site });
}
