"use client";

import { Suspense } from "react";
import { useParams, useSearchParams } from "next/navigation";
import { Editor } from "@/cut/components/Editor";

// Client-only: the id comes from the URL in the browser, so the hosted shell
// carries no server-rendered data. `from` records which tab opened the project
// so the editor's back button returns there.
function ProjectEditor() {
  const { id } = useParams<{ id: string }>();
  const from = useSearchParams().get("from");
  return <Editor projectId={id} from={from} />;
}

export default function ProjectPage() {
  return (
    <Suspense>
      <ProjectEditor />
    </Suspense>
  );
}
