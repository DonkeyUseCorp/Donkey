import { Suspense } from "react";
import { ProjectsHome } from "@/cut/components/ProjectsHome";

// Suspense: the view reads the open folder from ?folder=…, and useSearchParams
// needs a boundary in a statically prerendered shell.
export default function Home() {
  return (
    <Suspense>
      <ProjectsHome />
    </Suspense>
  );
}
