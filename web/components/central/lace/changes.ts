// The changes a Cookie run asked for in the team's apps, and what each came
// to — read only from the run's own steps and the member's approvals.

import type { CookieAction, CookieApproval, CookieRun } from "@/lib/api";

/** `HUBSPOT_UPDATE_DEAL` on hubspot → "Update deal". */
export function actionLabel(app: string, name: string): string {
  const prefix = app.replace(/[^a-z0-9]/gi, "");
  const words = name.replace(new RegExp(`^${prefix}_`, "i"), "").toLowerCase().replace(/_+/g, " ").trim();
  return words ? words[0].toUpperCase() + words.slice(1) : name;
}

/** The changes a run asked for in apps (reads left out), each with its approval when it has one. */
export function changesOf(run: CookieRun, approvals: CookieApproval[] = []): { action: CookieAction; approval?: CookieApproval }[] {
  return run.steps
    .filter((x) => x.action && x.action.effect !== "read")
    .map((x) => ({ action: x.action!, approval: x.action!.approval ? approvals.find((a) => a.id === x.action!.approval) : undefined }));
}

/** What a change came to, in a few words; `null` while it waits for a yes. */
export function changeOutcome(action: CookieAction, approval: CookieApproval | undefined, name: (app: string) => string): string | null {
  const where = name(action.app);
  switch (approval?.status ?? (action.state === "waiting" ? "pending" : action.state)) {
    case "pending":
      return null;
    case "approved":
      return `Done in ${where}`;
    case "done":
      // Ran without a card: say why no one was asked.
      return action.why ? `Done in ${where} · ${action.why}` : `Done in ${where}`;
    case "denied":
      return "You said no — nothing was changed";
    case "expired":
      return "Expired before a yes — nothing was changed";
    case "refused":
      return `${where} is set not to allow this`;
    case "read_first":
      return "Not made — Cookie hadn't read this record first";
    case "unknown":
      return `Unconfirmed — check ${where}`;
    default:
      return `${where} did not take it${approval?.result ? `: ${approval.result}` : ""}`;
  }
}
