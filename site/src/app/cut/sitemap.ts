import type { MetadataRoute } from "next";

import { DONKEYCUT_CANONICAL } from "@/cut/lib/hosts";

// Served at donkeycut.com/sitemap.xml via the proxy rewrite (src/proxy.ts);
// the apex keeps its own sitemap at src/app/sitemap.ts.
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: `${DONKEYCUT_CANONICAL}/`,
      changeFrequency: "weekly",
      priority: 1,
    },
  ];
}
