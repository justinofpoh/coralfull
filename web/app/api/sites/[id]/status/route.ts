import { NextResponse } from "next/server";
import { readSite, readStatus } from "@/lib/sites";

export const runtime = "nodejs";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const site = readSite(id);
  if (!site) return NextResponse.json({ error: "Site not found." }, { status: 404 });
  return NextResponse.json({ site, status: readStatus(id) });
}
