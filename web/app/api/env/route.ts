import { NextResponse } from "next/server";
import { pipelineIssues } from "@/lib/paths";

export const runtime = "nodejs";

export async function GET() {
  return NextResponse.json({ issues: pipelineIssues() });
}
