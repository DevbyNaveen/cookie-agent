import type { Metadata } from "next";

// Cookie's page wears Cookie's face in the tab: the orb with its eyes.
export const metadata: Metadata = {
  title: "Cookie",
  icons: {
    icon: [
      { url: "/cookie/icon-32.png?v=1", sizes: "32x32", type: "image/png" },
      { url: "/cookie/icon-64.png?v=1", sizes: "64x64", type: "image/png" },
    ],
    shortcut: "/cookie/icon-32.png?v=1",
    apple: [{ url: "/cookie/apple-180.png?v=1", sizes: "180x180", type: "image/png" }],
  },
};

export default function CookieLayout({ children }: { children: React.ReactNode }) {
  return children;
}
