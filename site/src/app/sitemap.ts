import type { MetadataRoute } from "next";

const SITE_URL = "https://donkeyuse.com";

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = new Date("2026-06-01");

  return [
    {
      changeFrequency: "weekly",
      lastModified,
      priority: 1,
      url: `${SITE_URL}/`,
    },
    {
      changeFrequency: "monthly",
      lastModified,
      priority: 0.8,
      url: `${SITE_URL}/install`,
    },
    {
      changeFrequency: "monthly",
      lastModified,
      priority: 0.8,
      url: `${SITE_URL}/pricing`,
    },
    {
      changeFrequency: "monthly",
      lastModified,
      priority: 0.8,
      url: `${SITE_URL}/donkeyvision`,
    },
    {
      changeFrequency: "yearly",
      lastModified,
      priority: 0.5,
      url: `${SITE_URL}/privacy`,
    },
    {
      changeFrequency: "yearly",
      lastModified,
      priority: 0.5,
      url: `${SITE_URL}/terms`,
    },
  ];
}
