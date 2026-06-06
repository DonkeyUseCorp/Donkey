"use client";

import { ApiKeysManager } from "@/app/dashboard/_components/ApiKeysManager";

export default function ApiKeysPage() {
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">API keys</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Create keys to authenticate Vision API requests. Send a key as a bearer
          token:{" "}
          <code className="rounded bg-muted px-1 py-0.5">
            Authorization: Bearer &lt;key&gt;
          </code>
          .
        </p>
      </div>
      <ApiKeysManager />
    </div>
  );
}
