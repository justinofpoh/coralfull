import { NextResponse } from "next/server";
import fs from "node:fs";
import path from "node:path";
import { siteDirectory } from "@/lib/paths";
import { existingPhotoNames, uniquePhotoName, updateSite } from "@/lib/sites";

export const runtime = "nodejs";
export const maxDuration = 300;

const SUPPORTED = new Set([".jpg", ".jpeg", ".png"]);

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const form = await request.formData();
  const files = form.getAll("photos").filter((value): value is File => value instanceof File);
  if (files.length === 0) {
    return NextResponse.json({ error: "No photos in this batch." }, { status: 400 });
  }

  const photosDir = path.join(siteDirectory(id), "photos");
  fs.mkdirSync(photosDir, { recursive: true });
  const used = existingPhotoNames(id);
  let saved = 0;

  for (const file of files) {
    const ext = path.extname(file.name).toLowerCase();
    if (!SUPPORTED.has(ext)) continue;
    const name = uniquePhotoName(photosDir, file.webkitRelativePath || file.name, used);
    const bytes = Buffer.from(await file.arrayBuffer());
    fs.writeFileSync(path.join(photosDir, name), bytes);
    saved += 1;
  }

  const photoCount = fs.readdirSync(photosDir).filter((name) =>
    SUPPORTED.has(path.extname(name).toLowerCase())
  ).length;
  updateSite(id, { photoCount, state: { kind: "importing" } });
  return NextResponse.json({ saved, photoCount });
}
