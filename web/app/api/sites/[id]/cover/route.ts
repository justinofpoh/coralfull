import { NextResponse } from "next/server";
import fs from "node:fs";
import { coverPath } from "@/lib/sites";

export const runtime = "nodejs";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const file = coverPath(id);
  if (!fs.existsSync(file)) {
    return new NextResponse(null, { status: 404 });
  }
  const data = fs.readFileSync(file);
  return new NextResponse(data, {
    headers: {
      "Content-Type": "image/jpeg",
      "Cache-Control": "public, max-age=60",
    },
  });
}
