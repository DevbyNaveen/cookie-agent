// Cookie's slice of the Console's projectNav.ts: the slug registry the page writes to.

const PROJECT_SLUGS = new Map<string, { org: string; project: string }>();

export function registerProjectSlug(projectId: string, org: string, project: string) {
  if (!projectId || !org || !project) return;
  PROJECT_SLUGS.set(projectId, { org, project });
}
