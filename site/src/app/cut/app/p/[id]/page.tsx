"use client";

import { Suspense } from "react";
import { useParams, useSearchParams } from "next/navigation";
import { Editor } from "@/cut/components/Editor";

// Client-only: the id comes from the URL in the browser, so the hosted shell
// carries no server-rendered data. `from` and `folder` record which tab (and
// folder within it) opened the project so the editor's back button returns
// there; `src` is the project's residency (cloud when set).
function ProjectEditor() {
  const { id } = useParams<{ id: string }>();
  const params = useSearchParams();
  return (
    <Editor
      projectId={id}
      from={params.get("from")}
      folder={params.get("folder")}
      src={params.get("src")}
    />
  );
}

export default function ProjectPage() {
  return (
    <Suspense>
      <ProjectEditor />
    </Suspense>
  );
}
