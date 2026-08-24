import { NextResponse } from "next/server";
import fs from "node:fs";
import type { AnalysisSequence } from "@/lib/types";
import { SITE_B_FALLBACK, manifestPath } from "@/lib/artifacts";

export const runtime = "nodejs";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const file = manifestPath(id);
  if (!fs.existsSync(file)) {
    return NextResponse.json(
      {
        error: `No analysis package found. Expected manifest at ${file}.`,
      },
      { status: 404 }
    );
  }
  const sequence = JSON.parse(fs.readFileSync(file, "utf8")) as AnalysisSequence;
  if (id === "site-b" && !sequence.mesh?.ply) {
    sequence.mesh = {
      ply: SITE_B_FALLBACK.ply,
      texture: SITE_B_FALLBACK.texture,
      vertexLabels: SITE_B_FALLBACK.vertexLabels,
      vertices: sequence.mesh?.vertices ?? null,
      faces: sequence.mesh?.faces ?? null,
      textureSize: sequence.mesh?.textureSize ?? null,
    };
  }
  return NextResponse.json(sequence);
}
