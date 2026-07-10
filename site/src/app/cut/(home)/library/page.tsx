import { Suspense } from "react";
import { LibraryView } from "@/cut/components/LibraryView";

// Suspense: the view reads the open folder from ?folder=…, and useSearchParams
// needs a boundary in a statically prerendered shell.
export default function LibraryPage() {
  return (
    <Suspense>
      <LibraryView />
    </Suspense>
  );
}
