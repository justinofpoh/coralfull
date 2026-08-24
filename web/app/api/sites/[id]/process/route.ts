import { NextResponse } from "next/server";
import { retryProcessing, startProcessing } from "@/lib/pipeline";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const body = (await request.json().catch(() => ({}))) as { retry?: boolean };
  try {
    const result = body.retry ? retryProcessing(id) : startProcessing(id);
    return NextResponse.json(result);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not start processing." },
      { status: 400 }
    );
  }
}
