import createMDX from "@next/mdx";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  pageExtensions: ["js", "jsx", "ts", "tsx", "md", "mdx"],
  // Cut (the video editor) uploads large media. Two independent limits apply:
  // its media route reads req.formData() (a route handler), so it isn't covered
  // by serverActions.bodySizeLimit; and src/proxy.ts runs on /api/cut/* on every
  // request, which makes Next clone the request body and truncate it at the 10MB
  // proxy default — a truncated multipart body then fails formData parsing. Raise
  // both so real video/audio files upload intact.
  experimental: {
    serverActions: { bodySizeLimit: "4gb" },
    proxyClientMaxBodySize: "4gb",
  },
};

const withMDX = createMDX({
  extension: /\.(md|mdx)$/,
});

export default withMDX(nextConfig);
