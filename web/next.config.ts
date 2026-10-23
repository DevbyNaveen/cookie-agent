import type { NextConfig } from "next";

// Cookie's page, served by Cookie itself. The page talks to `/api/gw/*` as it
// does inside Enkeon's Console; here that path is answered by a local
// `cookie serve`, at COOKIE_URL (default http://127.0.0.1:4747).
const COOKIE_URL = process.env.COOKIE_URL ?? "http://127.0.0.1:4747";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  async rewrites() {
    return [{ source: "/api/gw/:path*", destination: `${COOKIE_URL}/:path*` }];
  },
  async redirects() {
    return [{ source: "/", destination: "/me/local/cookie", permanent: false }];
  },
};

export default nextConfig;
