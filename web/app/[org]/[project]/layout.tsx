export function generateStaticParams() {
  return [{ project: "local" }];
}

export default function ProjectLayout({ children }: { children: React.ReactNode }) {
  return children;
}
