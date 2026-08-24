import { NextResponse } from "next/server";
import { cancelProcessing } from "@/lib/pipeline";
import { deleteSite, readSite, readStatus } from "@/lib/sites";

export const runtime = "nodejs";

/** Local pipeline state for a scan still being built on this machine. */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const site = readSite(id);
  if (!site) return NextResponse.json({ error: "Site not found." }, { status: 404 });
  return NextResponse.json({ site, status: readStatus(id) });
}

/**
 * Stops the pipeline and removes the local working directory.
 *
 * The backend record is deleted separately by the client, so that a failure to
 * reach the backend does not silently leave local photos behind, or the reverse.
 */
export async function DELETE(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  cancelProcessing(id);
  deleteSite(id);
  return NextResponse.json({ ok: true });
}
