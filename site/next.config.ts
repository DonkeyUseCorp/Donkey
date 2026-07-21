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
  // Cut is local-only, so /api/cut/* 404s on a hosted deploy and never spawns the
  // Claude Agent SDK. Its platform CLI binary (~220MB, and unusable on Vercel's
  // runtime anyway) otherwise gets traced into the function and blows past
  // Vercel's 250MB limit. Drop the whole SDK binary family from every function's
  // trace; the /api/cut route returns 404 before the SDK is ever imported.
  outputFileTracingExcludes: {
    "/*": ["./node_modules/@anthropic-ai/claude-agent-sdk-*/**/*"],
  },
};

const withMDX = createMDX({
  extension: /\.(md|mdx)$/,
});

export default withMDX(nextConfig);
