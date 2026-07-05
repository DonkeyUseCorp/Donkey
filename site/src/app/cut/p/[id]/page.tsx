"use client";

import { useParams } from "next/navigation";
import { Editor } from "@/cut/components/Editor";

// Client-only: the id comes from the URL in the browser, so the hosted shell
// carries no server-rendered data.
export default function ProjectPage() {
  const { id } = useParams<{ id: string }>();
  return <Editor projectId={id} />;
}
