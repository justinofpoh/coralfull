import { NextResponse } from "next/server";
import fs from "node:fs";
import { Readable } from "node:stream";
import { mimeFor, resolveSiteFile } from "@/lib/artifacts";

export const runtime = "nodejs";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string; path: string[] }> }
) {
  const { id, path: segments } = await params;
  const relative = segments.join("/");
  const file = resolveSiteFile(id, relative);
  if (!file || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    return NextResponse.json({ error: "File not found." }, { status: 404 });
  }
  const stream = Readable.toWeb(fs.createReadStream(file)) as ReadableStream;
  return new NextResponse(stream, {
    headers: {
      "Content-Type": mimeFor(file),
      "Cache-Control": "public, max-age=120",
    },
  });
}
