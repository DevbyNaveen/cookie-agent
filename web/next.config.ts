import type { NextConfig } from "next";

// Cookie's page, two ways:
// - `npm run build`: plain files in out/, served by `cookie page` itself, so the
//   page and Cookie's answers share one address and the page's own requests
//   (`/api/gw/*`, `/api/cookie/*`, the live stream) go to the same origin.
// - `npm run dev`: the dev server, which hands those requests to a `cookie page`
//   at COOKIE_URL (default http://127.0.0.1:4747).
const exporting = process.env.COOKIE_EXPORT === "1";
const COOKIE_URL = process.env.COOKIE_URL ?? "http://127.0.0.1:4747";

const nextConfig: NextConfig = exporting
  ? {
      reactStrictMode: true,
      output: "export",
      images: { unoptimized: true },
      // The live stream connects to the page's own address.
      env: { NEXT_PUBLIC_GATEWAY_URL: "" },
    }
  : {
      reactStrictMode: true,
      env: { NEXT_PUBLIC_GATEWAY_URL: COOKIE_URL },
      async rewrites() {
        return [
          { source: "/api/gw/:path*", destination: `${COOKIE_URL}/:path*` },
          { source: "/api/cookie/:path*", destination: `${COOKIE_URL}/api/cookie/:path*` },
        ];
      },
      async redirects() {
        return [{ source: "/", destination: "/me/local/cookie", permanent: false }];
      },
    };

export default nextConfig;
