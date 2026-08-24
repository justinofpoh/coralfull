import { NextResponse } from "next/server";
import { cancelProcessing } from "@/lib/pipeline";

export const runtime = "nodejs";

export async function POST(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  cancelProcessing(id);
  return NextResponse.json({ ok: true });
}
