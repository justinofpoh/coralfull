import { NextResponse } from "next/server";
import { cancelProcessing } from "@/lib/pipeline";
import { deleteSite, readSite, readStatus } from "@/lib/sites";

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

export async function DELETE(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  if (id === "site-a" || id === "site-b" || id === "site-c") {
    return NextResponse.json({ error: "Built-in sites cannot be deleted." }, { status: 400 });
  }
  cancelProcessing(id);
  deleteSite(id);
  return NextResponse.json({ ok: true });
}
