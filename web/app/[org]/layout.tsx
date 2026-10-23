import { Suspense } from "react";

// On your own computer there is one person and one folder: the page lives at
// /me/local/cookie. The page reads its address (useSearchParams), which a
// static build renders inside a Suspense boundary.
export function generateStaticParams() {
  return [{ org: "me" }];
}

export default function OrgLayout({ children }: { children: React.ReactNode }) {
  return <Suspense>{children}</Suspense>;
}
