// The ThinkingRoot connector catalog — only what we actually ship:
//   • Self-hosted Klavis (Apache-2.0) MCP servers on our Container Apps VNet
//   • Composio-managed OAuth (Gmail / Drive / OneDrive / Notion)
//
// Enabling a connector for a scope calls `installMcpServer(ws, spec)` (Slice 2),
// which mounts it into that brain's per-workspace MCP registry. The agent loop
// then sees it (routeTools) and dispatches per-user.
//
// Endpoint = the connector's internal Container Apps FQDN (same VNet as the engine,
// sub-ms). OAuth connectors need a per-user token from our OAuth broker; API-key
// connectors take a key; "none" need nothing. Composio mounts go through the
// gateway's gated endpoint (`api.mintConnectorMount`), never a direct URL.

/** Container Apps env domain hosting the connectors (set per deployment). */
export const CONNECTORS_DOMAIN =
  process.env.NEXT_PUBLIC_CONNECTORS_DOMAIN ?? "ashydesert-958b0016.eastus.azurecontainerapps.io";

export type ConnectorAuth = "oauth" | "api_key" | "none";

// ── Composio-managed OAuth connectors (2026-07-18) ─────────────────────────
// Gmail / Drive / OneDrive / Notion ride Composio's verified OAuth apps —
// no Google/Microsoft app review on our side. Each mount bakes the target
// workspace in as Composio's `user_id`, so per-user brains get per-user
// connected accounts for free. The API key never reaches the browser: the
// spec carries the literal `${COMPOSIO_API_KEY}` env-ref, resolved INSIDE
// the engine container (mcp/external_registry.rs resolve_env_ref).
export const COMPOSIO_SERVERS: Record<string, string> = {
  // 52 live servers on Composio (2026-08-09) — EVERY id verified against
  // its MCP tools/list from the production box before listing. The API key
  // never reaches the browser: the mount spec carries ${COMPOSIO_API_KEY},
  // resolved inside the engine container.
  airtable: "03046cbc-5f3f-4ad8-b654-7914eab3e05e",
  asana: "d0f839f8-f0c4-4c87-a3d3-634e959f8552",
  bitbucket: "28be2cf7-bcbf-41df-b565-63693e6fab83",
  box: "289c57ae-8f2c-4996-beca-fe628390aa27",
  brave_search: "f78ce4f3-eb2a-4ce2-a3d5-e0c59e956daf",
  cal_com: "5db31e62-b286-4828-b9d6-e0348bf33f0f",
  calendly: "b7ee4769-e29b-4807-b4d6-709bc4cc2bfd",
  canva: "46e9d7a5-b646-4944-8cfd-1eadf0c631af",
  clickup: "ed0dee3f-7a56-4d8b-bceb-0aebca247adf",
  confluence: "ae6bc118-216b-4fc5-9d8a-655e2c3e7e57",
  discord: "b43e3fb2-e1d9-4254-99de-80015d0654e7",
  dropbox: "de9f5077-9b77-4450-9357-bfaafac317d5",
  figma: "b3ee067c-5065-48b3-9004-c4a1bf638ca3",
  github: "0548bcc4-1623-4f46-aa1e-db800d93e860",
  gitlab: "b967f103-1cf9-4659-bf53-2e1c41e22cb8",
  gmail: "179b1ce9-0896-4360-84c6-1aa576e61d1e",
  google_analytics: "cf3f7e36-bc46-4507-95e2-7672a4a3855c",
  google_calendar: "e1015e0d-6be1-41c5-a1a7-7c5e697178b2",
  google_drive: "24292323-be66-445e-a27f-7400c7209402",
  google_meet: "425b6f5e-c550-4a63-9560-c5a993507d0e",
  google_sheets: "de782735-6026-45ff-a817-6dc00a4147e3",
  // 2026-08-24. `tr-google-slides`, verified against its live tools/list before
  // listing (7 tools). Consent asks for BOTH `auth/presentations` AND
  // `auth/drive` — Composio's managed OAuth app requests them together — so a
  // user connecting Slides grants Drive access too. Worth knowing before it is
  // answered on a security questionnaire.
  google_slides: "08535a82-c82a-493d-a374-cf8945943996",
  greenhouse: "1e856b9c-cc23-4775-b0c9-bc425c5c5a57",
  hacker_news: "7a490577-d756-4f04-aa54-d4a20b730308",
  hubspot: "76fcda50-7df1-4cb8-9bd2-5d53147b7bba",
  instagram: "bd3817ae-f250-4d5b-b804-135fe6499079",
  intercom: "45bd1252-7ae5-4327-8a05-3cfffd461d4f",
  jira: "ad88c216-5b93-448b-aba9-308687a3c057",
  linear: "c08ee7b5-7165-4e8c-89b6-555fa7171704",
  linkedin: "7cd0cfd6-b34d-4d23-a1ee-05f3a8d762ef",
  mailchimp: "0103ef41-60c6-47a9-ae0c-81a0e4143a3b",
  microsoft_teams: "257e1b0b-e96e-47ee-aa7d-1db5224d5008",
  miro: "5a74d280-5027-41bf-a0d5-2d400249f9b3",
  neon: "6be0b841-4619-473f-96a1-3e0b14752fcc",
  notion: "e042211f-18ad-4671-8e6e-e35ddb1cb0d0",
  onedrive: "992a2bc5-715a-4676-bafe-a827295f1f75",
  outlook: "8c853f17-f10a-423b-92d4-c87026409c85",
  pagerduty: "be7c5b0d-b84a-4e9e-a16c-5850e3186e14",
  quickbooks: "d5f77f5f-d20c-4e7c-8841-cb451c181e1d",
  reddit: "a9915786-8668-43eb-8772-f9c37bf8cb2c",
  salesforce: "a791ecc2-c8fb-4c94-8545-1865ab215338",
  sentry: "3126662f-e380-49ea-bbff-7caa84822fc7",
  sharepoint: "a25f6c7a-a47d-492e-a219-9b8e670eae80",
  slack: "e7068ac4-d241-4073-87b3-821fadcc672f",
  square: "8086e671-7b70-455c-8bca-eab16a5d48ce",
  stripe: "a3c59924-5a0e-4c4f-b263-894b80adb19e",
  supabase: "d0484d0f-0ff8-4b32-a5ed-d5e3341c5a40",
  trello: "ad433a29-379f-4a55-b9a4-0956461cbf00",
  typeform: "40a2577d-e008-4db6-a56c-7b2b51e2ce95",
  whatsapp: "b3ce7dff-1f93-41e7-a7eb-ffb42007aee6",
  youtube: "95062cee-b219-42ad-9ee5-29f2ec8f384e",
  zendesk: "44d82411-84b2-49bf-8f8a-3a0ae2d19455",
  zoho_crm: "dda552a3-8e22-42d6-a608-30cdf1a7a033",
  zoom: "f86b6308-e2fd-49d1-80a8-ad138777f864",
  // ── 2026-08-10: 26 user-key toolkits (API_KEY / BASIC / BEARER).
  // Composio holds no OAuth app for these, but creating their auth config
  // needs nothing from US — the end user brings their own key at connect
  // time, which is what made them ours to ship in code.
  apollo: "ecc983b2-ca17-416b-91e0-958bc963b6b4",
  ashby: "9a47eed1-b336-4acc-84d5-2115fdfdc9f0",
  bamboohr: "e2adeb8e-371c-4320-be2c-1cce43d447b4",
  circleci: "c1c67b89-8cd0-4df5-89ef-cdaf183cd6c4",
  close: "a50fba64-4d2b-40b2-989a-a61f00597c77",
  cloudflare: "ecf87ac1-ae69-4338-affb-6fbf14abb914",
  coda: "a2a3bbc9-b456-421a-b17a-c95eedc4182b",
  databricks: "329f7edc-7b78-41d1-a9c8-537b1c4739ea",
  datadog: "2eeb5281-5031-46e1-bfce-5beec43eff86",
  firecrawl: "cfbb8829-a6d4-4b58-b4c0-eca6610f0c52",
  fireflies: "9a0681bc-3fd3-4c27-baa7-8091e094017c",
  freshdesk: "a4ccc1cd-9927-4625-902c-c6dd3c115006",
  front: "8eeb868b-5dbf-46e2-93f2-e219a1e803f9",
  guru: "5ab5ff0c-ee1b-483a-99be-351232851047",
  jotform: "e1e08927-6e2e-479a-be9c-13992c6b7be8",
  mixpanel: "1b6b9b9f-7d2b-4d2b-b0ce-e78d1d8ee9a4",
  pipedrive: "688fa003-a0d4-4a15-8e69-f29ddf87bf19",
  posthog: "292042dc-17a2-4acf-a3fa-30aba828ed10",
  postman: "b3621868-21e9-46c8-9728-2e72d60b7244",
  resend: "4dc91522-a415-4742-bff9-64d0f8e27002",
  rippling: "2204b856-5868-4866-ac94-82307a858aa3",
  servicenow: "1a694fbf-ecf0-473a-9bdd-3801941f1237",
  shopify: "0b646009-885f-450b-9da5-1021bf7216e7",
  telegram: "b60342d0-43e7-4ddf-91b5-29b4babb2db1",
  vercel: "e703fb95-5b8b-47f7-9c37-80028bfe360b",
  webflow: "1ec094bf-c63c-4f57-8ca4-f5be80772e3c",
  // ── Business expansion (2026-08-30) — 20 servers created + tools/list-
  // verified live (1,662 tools). Managed-OAuth or user-key only; the OAuth
  // toolkits that need OUR OWN developer app per provider are NOT here.
  monday: "578e8c39-98f3-4ad6-ab94-bcd28c631b78",
  basecamp: "5860927a-6d7c-43b1-89e1-398a3edd0c85",
  todoist: "e86427d2-8e50-4628-b1d4-a531d6e08eb6",
  dynamics365: "9ec5cb50-b9e4-4cca-8967-f586ee73d134",
  facebook: "f9dbe7db-809f-4deb-a82e-adcafccd734a",
  pinterest: "495171dc-4ec5-4e99-8e2d-c08e35146810",
  sendgrid: "296ddd2f-7d6c-47ea-987e-9018876e90f1",
  amplitude: "c5008b58-e4a3-4555-9460-97b9759fc5db",
  segment: "7f51a9ae-3011-459b-b6b6-9aa9506d42a2",
  gorgias: "85083ebf-7748-4bf6-a708-d8757c3b56f1",
  zoho_desk: "583cf0b5-15bb-4603-822b-a2ba8228f7f7",
  crisp: "bbd58a00-3ffd-4730-a95b-6d0c8e001164",
  freshbooks: "6b0188a2-9ad6-4734-a8fb-0de82122434b",
  zoho_books: "e0305a4e-6883-4ed5-be65-67cab9ce2036",
  zoho_invoice: "4c5b3f51-5ad0-479c-bf37-b2cf50c675f6",
  recurly: "826e779f-c705-4dc2-b475-b87b28f8d72c",
  maxio: "7f947ad0-9aba-4159-b69f-dcd02b70c6b0",
  pandadoc: "20c4f35e-81f6-46be-81c3-365d99ba0082",
  render: "a088a9f9-6ce5-4250-b650-abdbf22c3288",
  jumpcloud: "b54f7310-57ff-4da5-bc6a-8407cd7fb023",

};

/** Composio toolkit slug per console slug (their naming differs from ours). */
export const COMPOSIO_TOOLKITS: Record<string, string> = {
  airtable: "airtable",
  asana: "asana",
  bitbucket: "bitbucket",
  box: "box",
  brave_search: "composio_search",
  cal_com: "cal",
  calendly: "calendly",
  canva: "canva",
  clickup: "clickup",
  confluence: "confluence",
  discord: "discord",
  dropbox: "dropbox",
  figma: "figma",
  github: "github",
  gitlab: "gitlab",
  gmail: "gmail",
  google_analytics: "google_analytics",
  google_calendar: "googlecalendar",
  google_drive: "googledrive",
  google_meet: "googlemeet",
  google_sheets: "googlesheets",
  google_slides: "googleslides",
  greenhouse: "greenhouse",
  hacker_news: "hackernews",
  hubspot: "hubspot",
  instagram: "instagram",
  intercom: "intercom",
  jira: "jira",
  linear: "linear",
  linkedin: "linkedin",
  mailchimp: "mailchimp",
  microsoft_teams: "microsoft_teams",
  miro: "miro",
  notion: "notion",
  onedrive: "one_drive",
  outlook: "outlook",
  pagerduty: "pagerduty",
  quickbooks: "quickbooks",
  reddit: "reddit",
  salesforce: "salesforce",
  sentry: "sentry",
  sharepoint: "share_point",
  slack: "slack",
  square: "square",
  stripe: "stripe",
  supabase: "supabase",
  trello: "trello",
  typeform: "typeform",
  whatsapp: "whatsapp",
  youtube: "youtube",
  zendesk: "zendesk",
  zoho_crm: "zoho",
  zoom: "zoom",
  // ── 2026-08-10: 26 user-key toolkits (API_KEY / BASIC / BEARER).
  // Composio holds no OAuth app for these, but creating their auth config
  // needs nothing from US — the end user brings their own key at connect
  // time, which is what made them ours to ship in code.
  apollo: "apollo",
  ashby: "ashby",
  bamboohr: "bamboohr",
  circleci: "circleci",
  close: "close",
  cloudflare: "cloudflare",
  coda: "coda",
  databricks: "databricks",
  datadog: "datadog",
  firecrawl: "firecrawl",
  fireflies: "fireflies",
  freshdesk: "freshdesk",
  front: "front",
  guru: "guru",
  jotform: "jotform",
  mixpanel: "mixpanel",
  neon: "neon",
  pipedrive: "pipedrive",
  posthog: "posthog",
  postman: "postman",
  resend: "resend",
  rippling: "rippling",
  servicenow: "servicenow",
  shopify: "shopify",
  telegram: "telegram",
  vercel: "vercel",
  webflow: "webflow",
};

/** Klavis servers we actually run on Container Apps. A slug NOT in here and NOT
 *  in COMPOSIO_SERVERS has no backing endpoint — `connectorEndpoint` would point
 *  at a host that does not exist, the install would "succeed", and the user would
 *  stare at 0 tools with no error. Listing IS the contract: `CONNECTOR_CATALOG`
 *  filters on this, so an unbacked connector can never reach the UI. */
export const KLAVIS_SERVERS: ReadonlySet<string> = new Set([
  // ⚠️ EMPTY since 2026-08-09 — the Klavis Container Apps fleet lived on the
  // Azure VNet-internal env (`ashydesert-…azurecontainerapps.io`), which is
  // NXDOMAIN from the AWS production box (verified live). Every install
  // would "succeed" and serve 0 tools — exactly what this contract exists
  // to prevent. Restore the slugs one by one as servers are re-hosted
  // reachable from eu-central-1 (previous set: slack, telegram,
  // hacker_news, supabase, resend, firecrawl, brave_search).
]);

/** Connectors served by the VENDOR'S OWN official MCP server, not Composio.
 *
 *  Composio has no `aws` and no `azure` toolkit — both 404 against the live API
 *  — because AWS and Microsoft each shipped their own MCP server instead. These
 *  reach that server directly, and the gateway mints a short-lived bearer per
 *  call from a trust the customer grants in their own account (an IAM role, an
 *  Entra consent). No customer credential is ever stored.
 *
 *  `azure_devops` rather than `azure`, deliberately: Microsoft hosts NO remote
 *  MCP endpoint for Azure generally — that server is local-install only — and
 *  the only GA remote one is Azure DevOps. Naming the tile `azure` would
 *  promise subscriptions and resources that this connector cannot reach. */
export const DIRECT_CONNECTORS: ReadonlySet<string> = new Set(["aws", "azure_devops"]);

/** True when `slug` resolves to a real endpoint (Composio-managed, self-hosted,
 *  or the vendor's own official MCP server). */
export function isBacked(slug: string): boolean {
  return !!COMPOSIO_SERVERS[slug] || KLAVIS_SERVERS.has(slug) || DIRECT_CONNECTORS.has(slug);
}

/** Connectors the gateway can actually SYNC (a delta adapter exists in
 *  `services/gateway/src/connector_sync.rs`). Deliberately narrower than the
 *  catalog: being tool-callable says nothing about being able to track changes,
 *  and conflating the two is how a product advertises sync it does not have.
 *  Keep in lockstep with `Provider::parse` — the gateway 400s anything else. */
/** Connectors that pull documents INTO the brain, as opposed to merely being
 *  callable by an agent. The distinction is load-bearing: 52 toolkits are
 *  tool-callable and only these can sync, and offering sync we do not have is
 *  the kind of claim that gets found out by a customer rather than by us.
 *
 *  MUST stay in lockstep with `syncable_slugs()` in
 *  `services/gateway/src/connector_sync.rs` — a slug offered here but
 *  unparseable there 400s on enable. Both sides carry a test. */
export const SYNCABLE_CONNECTORS: ReadonlySet<string> = new Set([
  // Hand-written adapters: these providers have semantics a spec cannot
  // express (Drive's change feed and export rules, Gmail's epoch cursor,
  // HubSpot's property bag, GitHub's owner/repo identity).
  "google_drive",
  "onedrive",
  "notion",
  "github",
  "hubspot",
  "gmail",
  // Spec-driven: a row in the gateway's SPECS table, not a code path.
  "linear",
  "confluence",
  "jira",
  "outlook",
  "zendesk",
  // Two-level: the documents live inside containers (channels, projects,
  // workspaces), so the walk enumerates those first. Slack folds a page of
  // messages into one transcript — a single Slack line is not a memory.
  "slack",
  "asana",
  "clickup",
  // Boards, then each board's cards; the board is the branch.
  "trello",
]);

/** Composio's `user_id` — the ONLY thing that selects which connected account a
 *  tool call resolves to. It MUST be globally unique across tenants.
 *
 *  It used to be the bare workspace name, and every project on the platform is
 *  created with `workspace_name = 'main'` (61 of 61 in production on
 *  2026-08-10). So every project shared one Composio identity: a project that
 *  mounted Gmail resolved to whichever Gmail account another project had
 *  connected. Verified by calling the Gmail toolkit with nothing but the
 *  platform key and the string `main` — it returned a live mailbox with no
 *  project identity involved anywhere in the request.
 *
 *  The project id is the tenant boundary, so it belongs in the identity. The
 *  separator is `.` because it is the one character in NEITHER side: project
 *  ids are `proj_<hex>`, workspace names are `[A-Za-z0-9_-]`. An underscore is
 *  genuinely ambiguous — `proj_a` + `_b` and `proj_a_` + `b` both render as
 *  `proj_a___b`, which would put two tenants on one account.
 *
 *  MUST stay byte-identical to `composio_user_id` in
 *  `services/gateway/src/connector_sync.rs`: the console mints the account under
 *  this identity and the gateway's syncer polls it. A drift is not a crash, it
 *  is a connector that authorizes cleanly and then syncs nothing, forever. */
export function composioUserId(projectId: string, workspace: string): string {
  return `${projectId}.${workspace}`;
}

// There is deliberately NO `composioEndpoint` here any more.
//
// It used to build the URL the engine mounted, pointing straight at
// `backend.composio.dev` with `user_id` in the query string. Two things were
// wrong with that and both are structural, not cosmetic:
//
//   • the gateway never saw the call, so no write could be gated, metered or
//     recorded — an agent could send mail or delete a file with nothing
//     standing between the model and the user's account;
//   • the tenant was a URL parameter sitting in engine config, so anything able
//     to read or edit that config could point the mount at another tenant.
//
// Mounts now come from `api.mintConnectorMount`, which returns a gateway URL
// carrying an opaque token; the gateway resolves the tenant server-side. This
// note is here because a helper that builds an ungated Composio URL is a
// one-line reintroduction of both problems.

export interface CatalogConnector {
  slug: string; // engine server name (also the Container App suffix)
  name: string; // display name
  category: string;
  auth: ConnectorAuth;
  /** MCP path. Klavis servers canonicalize on `/mcp/`; our FastMCP-built
   *  servers (e.g. telegram) on `/mcp`. Default `/mcp/`. */
  path?: string;
  /** Rollout tier (NAV-170): 1 = launch core (knowledge sources), 2 = fast
   *  follow (departments), 3 = breadth. Backed connectors are live whatever
   *  their tier; unbacked ones display as rolling out. 4 = uncurated — an entry
   *  that came from the live catalog (NAV-267) and that nobody here has chosen
   *  a name, category or brand mark for, so it sorts below everything we did. */
  tier?: 1 | 2 | 3 | 4;
  /** simple-icons slug for the brand mark (cdn.simpleicons.org). Absent or
   *  404 → the UI falls back to a letter tile — never a broken image. */
  logo?: string;
}

/** MCP endpoint the ENGINE uses to reach the connector over the VNet. Connectors
 *  run with `--ingress external` on the INTERNAL env (= VNet-exposed, not public),
 *  so the FQDN has NO `.internal.`. Use each server's canonical path to avoid the
 *  307. PROVEN LIVE 2026-06-18 (hacker-news `/mcp/`, telegram `/mcp` → tools/list). */
export function connectorEndpoint(slug: string, path = "/mcp/"): string {
  return `https://tr-conn-${slug.replace(/_/g, "-")}.${CONNECTORS_DOMAIN}${path}`;
}

/** DISPLAY-ONLY masked endpoint for the Console panel. The real host is a
 *  private VNet address (`--ingress external` on an INTERNAL env → resolvable
 *  only inside `tr-engineVNET`), so a copied raw URL is both unreachable and
 *  off-brand. We keep the `tr-conn-<slug>` prefix + transport + `/mcp` path so
 *  the SHAPE is recognizable, but mask every host segment (env-id, region, even
 *  the Azure TLD) → no one can read which infra it is or use it. Never used for
 *  the actual `installMcpServer` call — that always takes `connectorEndpoint`. */
export function maskedConnectorEndpoint(slug: string, path = "/mcp/"): string {
  const host = `tr-conn-${slug.replace(/_/g, "-")}.${CONNECTORS_DOMAIN}`;
  const [sub, ...rest] = host.split(".");
  const masked = [sub, ...rest.map((seg) => "x".repeat(Math.min(seg.length, 8)))].join(".");
  return `https://${masked}${path}`;
}

/**
 * Everything we know how to ship.
 *
 * Google Docs has no row, and that is the rule: a file type inside Drive earns
 * its own row only when the toolkit does something Drive CANNOT. Drive reads
 * every Google-native file — `is_google_native` in `connector_sync.rs` exports
 * Docs/Sheets/Slides as text — so a row that only re-reads them would be a
 * second door to the same data. Sheets and Slides are rows because their
 * toolkits AUTHOR: Sheets updates ranges, Slides builds a deck from markdown.
 * That is a capability Drive does not have, not a duplicate of one it does.
 * Same test for Word/Excel/PowerPoint inside OneDrive.
 *
 * A slug here is only exported if `isBacked` — see `CONNECTOR_CATALOG`.
 */
const KNOWN_CONNECTORS: CatalogConnector[] = [
  // ── Vendor-owned MCP servers (not Composio) ──────────────────────────────
  // `auth: "none"` describes the BROWSER's part, which is the only part this
  // field governs: there is no consent tab, because the trust is granted in the
  // customer's own AWS or Entra console and named here by a role ARN or tenant
  // id. The gateway then mints a short-lived bearer per call.
  { slug: "aws", name: "AWS", category: "Developer", auth: "none", tier: 1, logo: "amazonwebservices" },
  { slug: "azure_devops", name: "Azure DevOps", category: "Developer", auth: "none", tier: 1, logo: "azuredevops" },

  // ── Tier 1 — launch core: where company knowledge lives ──────────────────
  { slug: "gmail", name: "Gmail", category: "Communication", auth: "oauth", tier: 1, logo: "gmail" }, // Composio
  { slug: "slack", name: "Slack", category: "Communication", auth: "oauth", tier: 1, logo: "slack" },
  { slug: "microsoft_teams", name: "Microsoft Teams", category: "Communication", auth: "oauth", tier: 1 },
  { slug: "outlook", name: "Outlook", category: "Communication", auth: "oauth", tier: 1 },
  { slug: "notion", name: "Notion", category: "Docs & Wikis", auth: "oauth", tier: 1, logo: "notion" }, // Composio
  { slug: "google_drive", name: "Google Drive", category: "Docs & Wikis", auth: "oauth", tier: 1, logo: "googledrive" }, // Composio — incl. Docs/Sheets
  { slug: "confluence", name: "Confluence", category: "Docs & Wikis", auth: "oauth", tier: 1, logo: "confluence" },
  { slug: "onedrive", name: "Microsoft 365", category: "Docs & Wikis", auth: "oauth", tier: 1 }, // Composio — incl. Word/Excel/PPT
  { slug: "sharepoint", name: "SharePoint", category: "Docs & Wikis", auth: "oauth", tier: 1 },
  { slug: "dropbox", name: "Dropbox", category: "Docs & Wikis", auth: "oauth", tier: 1, logo: "dropbox" },
  { slug: "linear", name: "Linear", category: "Work Tracking", auth: "oauth", tier: 1, logo: "linear" },
  { slug: "jira", name: "Jira", category: "Work Tracking", auth: "oauth", tier: 1, logo: "jira" },
  { slug: "asana", name: "Asana", category: "Work Tracking", auth: "oauth", tier: 1, logo: "asana" },
  { slug: "clickup", name: "ClickUp", category: "Work Tracking", auth: "oauth", tier: 1, logo: "clickup" },
  { slug: "trello", name: "Trello", category: "Work Tracking", auth: "oauth", tier: 1, logo: "trello" },
  { slug: "github", name: "GitHub", category: "Developer", auth: "oauth", tier: 1, logo: "github" }, // Composio
  { slug: "gitlab", name: "GitLab", category: "Developer", auth: "oauth", tier: 1, logo: "gitlab" },
  { slug: "hubspot", name: "HubSpot", category: "Sales", auth: "oauth", tier: 1, logo: "hubspot" }, // Composio — syncs companies only
  { slug: "salesforce", name: "Salesforce", category: "Sales", auth: "oauth", tier: 1, logo: "salesforce" },
  { slug: "google_calendar", name: "Google Calendar", category: "Scheduling", auth: "oauth", tier: 1, logo: "googlecalendar" },
  { slug: "calendly", name: "Calendly", category: "Scheduling", auth: "oauth", tier: 1, logo: "calendly" },

  // ── Tier 2 — fast follow: the departments join the brain ─────────────────
  { slug: "zendesk", name: "Zendesk", category: "Support", auth: "oauth", tier: 2, logo: "zendesk" },
  { slug: "intercom", name: "Intercom", category: "Support", auth: "oauth", tier: 2, logo: "intercom" },
  { slug: "freshdesk", name: "Freshdesk", category: "Support", auth: "api_key", tier: 2 },
  { slug: "front", name: "Front", category: "Support", auth: "api_key", tier: 2 },
  { slug: "zoom", name: "Zoom", category: "Meetings", auth: "oauth", tier: 2, logo: "zoom" },
  { slug: "google_meet", name: "Google Meet", category: "Meetings", auth: "oauth", tier: 2, logo: "googlemeet" },
  { slug: "fireflies", name: "Fireflies", category: "Meetings", auth: "api_key", tier: 2 },
  { slug: "pipedrive", name: "Pipedrive", category: "Sales", auth: "api_key", tier: 2 },
  { slug: "zoho_crm", name: "Zoho CRM", category: "Sales", auth: "oauth", tier: 2, logo: "zoho" },
  { slug: "apollo", name: "Apollo", category: "Sales", auth: "api_key", tier: 2 },
  { slug: "close", name: "Close", category: "Sales", auth: "api_key", tier: 2 },
  { slug: "google_sheets", name: "Google Sheets", category: "Data & Analytics", auth: "oauth", tier: 2, logo: "googlesheets" },
  { slug: "google_slides", name: "Google Slides", category: "Docs & Wikis", auth: "oauth", tier: 2, logo: "googleslides" },
  { slug: "airtable", name: "Airtable", category: "Data & Analytics", auth: "oauth", tier: 2, logo: "airtable" },
  { slug: "mixpanel", name: "Mixpanel", category: "Data & Analytics", auth: "api_key", tier: 2, logo: "mixpanel" },
  { slug: "posthog", name: "PostHog", category: "Data & Analytics", auth: "api_key", tier: 2, logo: "posthog" },
  { slug: "google_analytics", name: "Google Analytics", category: "Data & Analytics", auth: "oauth", tier: 2, logo: "googleanalytics" },
  { slug: "stripe", name: "Stripe", category: "Finance", auth: "api_key", tier: 2, logo: "stripe" },
  { slug: "quickbooks", name: "QuickBooks", category: "Finance", auth: "oauth", tier: 2, logo: "quickbooks" },
  { slug: "bamboohr", name: "BambooHR", category: "HR & Hiring", auth: "api_key", tier: 2 },
  { slug: "greenhouse", name: "Greenhouse", category: "HR & Hiring", auth: "api_key", tier: 2, logo: "greenhouse" },
  { slug: "mailchimp", name: "Mailchimp", category: "Marketing", auth: "oauth", tier: 2, logo: "mailchimp" },
  { slug: "webflow", name: "Webflow", category: "Marketing", auth: "api_key", tier: 2, logo: "webflow" },
  { slug: "typeform", name: "Typeform", category: "Forms & Surveys", auth: "oauth", tier: 2, logo: "typeform" },

  // ── Tier 3 — breadth: action tools + verticals ───────────────────────────
  { slug: "bitbucket", name: "Bitbucket", category: "Developer", auth: "oauth", tier: 3, logo: "bitbucket" },
  { slug: "sentry", name: "Sentry", category: "Developer", auth: "oauth", tier: 3, logo: "sentry" },
  { slug: "pagerduty", name: "PagerDuty", category: "Developer", auth: "oauth", tier: 3, logo: "pagerduty" },
  { slug: "datadog", name: "Datadog", category: "Developer", auth: "api_key", tier: 3, logo: "datadog" },
  { slug: "circleci", name: "CircleCI", category: "Developer", auth: "api_key", tier: 3, logo: "circleci" },
  { slug: "vercel", name: "Vercel", category: "Developer", auth: "api_key", tier: 3, logo: "vercel" },
  { slug: "supabase", name: "Supabase", category: "Developer", auth: "api_key", tier: 3, logo: "supabase" },
  { slug: "neon", name: "Neon", category: "Developer", auth: "api_key", tier: 3, logo: "neon" },
  { slug: "cloudflare", name: "Cloudflare", category: "Developer", auth: "api_key", tier: 3, logo: "cloudflare" },
  { slug: "postman", name: "Postman", category: "Developer", auth: "api_key", tier: 3, logo: "postman" },
  { slug: "figma", name: "Figma", category: "Design", auth: "oauth", tier: 3, logo: "figma" },
  { slug: "miro", name: "Miro", category: "Design", auth: "oauth", tier: 3, logo: "miro" },
  { slug: "canva", name: "Canva", category: "Design", auth: "oauth", tier: 3, logo: "canva" },
  { slug: "guru", name: "Guru", category: "Docs & Wikis", auth: "api_key", tier: 3 },
  { slug: "coda", name: "Coda", category: "Docs & Wikis", auth: "api_key", tier: 3, logo: "coda" },
  { slug: "box", name: "Box", category: "Docs & Wikis", auth: "oauth", tier: 3, logo: "box" },
  { slug: "telegram", name: "Telegram", category: "Communication", auth: "api_key", tier: 3, logo: "telegram" },
  { slug: "whatsapp", name: "WhatsApp", category: "Communication", auth: "api_key", tier: 3, logo: "whatsapp" },
  { slug: "discord", name: "Discord", category: "Communication", auth: "oauth", tier: 3, logo: "discord" },
  { slug: "linkedin", name: "LinkedIn", category: "Social", auth: "oauth", tier: 3 },
  { slug: "reddit", name: "Reddit", category: "Social", auth: "oauth", tier: 3, logo: "reddit" },
  { slug: "youtube", name: "YouTube", category: "Social", auth: "oauth", tier: 3, logo: "youtube" },
  { slug: "instagram", name: "Instagram", category: "Social", auth: "oauth", tier: 3, logo: "instagram" },
  { slug: "shopify", name: "Shopify", category: "E-commerce", auth: "api_key", tier: 3, logo: "shopify" },
  { slug: "servicenow", name: "ServiceNow", category: "Enterprise Ops", auth: "api_key", tier: 3 },
  { slug: "square", name: "Square", category: "Finance", auth: "oauth", tier: 3, logo: "square" },
  { slug: "databricks", name: "Databricks", category: "Data & Analytics", auth: "api_key", tier: 3, logo: "databricks" },
  { slug: "rippling", name: "Rippling", category: "HR & Hiring", auth: "api_key", tier: 3 },
  { slug: "ashby", name: "Ashby", category: "HR & Hiring", auth: "api_key", tier: 3 },
  { slug: "jotform", name: "Jotform", category: "Forms & Surveys", auth: "api_key", tier: 3, logo: "jotform" },
  { slug: "cal_com", name: "Cal.com", category: "Scheduling", auth: "api_key", tier: 3, logo: "caldotcom" },
  { slug: "hacker_news", name: "Hacker News", category: "Social", auth: "none", tier: 3, logo: "ycombinator" },
  { slug: "resend", name: "Resend", category: "Marketing", auth: "api_key", tier: 3, logo: "resend" },
  { slug: "firecrawl", name: "Firecrawl", category: "Developer", auth: "api_key", tier: 3 },
  { slug: "brave_search", name: "Brave Search", category: "Developer", auth: "api_key", tier: 3, logo: "brave" },
  // ── Business expansion (2026-08-30), tier 2 — every slug here is backed
  // by a live, tools/list-verified Composio server (see COMPOSIO_SERVERS). ──
  { slug: "monday", name: "Monday.com", category: "Work Tracking", auth: "oauth", tier: 2, logo: "monday" },
  { slug: "basecamp", name: "Basecamp", category: "Work Tracking", auth: "oauth", tier: 2, logo: "basecamp" },
  { slug: "todoist", name: "Todoist", category: "Work Tracking", auth: "oauth", tier: 2, logo: "todoist" },
  { slug: "dynamics365", name: "Dynamics 365", category: "Sales", auth: "oauth", tier: 2, logo: "dynamics365" },
  { slug: "facebook", name: "Facebook Pages", category: "Social", auth: "oauth", tier: 2, logo: "facebook" },
  { slug: "pinterest", name: "Pinterest", category: "Social", auth: "oauth", tier: 2, logo: "pinterest" },
  { slug: "sendgrid", name: "SendGrid", category: "Marketing", auth: "api_key", tier: 2, logo: "sendgrid" },
  { slug: "amplitude", name: "Amplitude", category: "Data & Analytics", auth: "api_key", tier: 2, logo: "amplitude" },
  { slug: "segment", name: "Segment", category: "Data & Analytics", auth: "api_key", tier: 2, logo: "segment" },
  { slug: "gorgias", name: "Gorgias", category: "Support", auth: "oauth", tier: 2, logo: "gorgias" },
  { slug: "zoho_desk", name: "Zoho Desk", category: "Support", auth: "oauth", tier: 2, logo: "zoho_desk" },
  { slug: "crisp", name: "Crisp", category: "Support", auth: "api_key", tier: 2, logo: "crisp" },
  { slug: "freshbooks", name: "FreshBooks", category: "Finance", auth: "oauth", tier: 2, logo: "freshbooks" },
  { slug: "zoho_books", name: "Zoho Books", category: "Finance", auth: "oauth", tier: 2, logo: "zoho_books" },
  { slug: "zoho_invoice", name: "Zoho Invoice", category: "Finance", auth: "oauth", tier: 2, logo: "zoho_invoice" },
  { slug: "recurly", name: "Recurly", category: "Finance", auth: "api_key", tier: 2, logo: "recurly" },
  { slug: "maxio", name: "Maxio", category: "Finance", auth: "api_key", tier: 2, logo: "maxio" },
  { slug: "pandadoc", name: "PandaDoc", category: "Docs & Wikis", auth: "api_key", tier: 2, logo: "pandadoc" },
  { slug: "render", name: "Render", category: "Developer", auth: "api_key", tier: 2, logo: "render" },
  { slug: "jumpcloud", name: "JumpCloud", category: "Developer", auth: "api_key", tier: 2, logo: "jumpcloud" },

];

/**
 * Shipped catalog — only connectors with a real endpoint behind them.
 * Nothing else is browsable or installable from the Console.
 */
export const CONNECTOR_CATALOG: CatalogConnector[] = KNOWN_CONNECTORS.filter((c) =>
  isBacked(c.slug),
);

/** The FULL tiered catalog (NAV-170) for gallery surfaces in both consoles:
 *  every known connector, `live` when a real endpoint backs it, `rolling`
 *  otherwise. Rolling entries NEVER get a Connect action — the isBacked
 *  contract holds; they exist so the roadmap is visible and flipping one live
 *  is purely a COMPOSIO_SERVERS entry. Sorted tier-then-name. */
export type ConnectorStatus = "live" | "rolling" | "builtin" | "database";

export interface FullCatalogEntry extends CatalogConnector {
  status: ConnectorStatus;
  /** Absolute logo URL from the live catalog (NAV-267). Only a fallback for
   *  entries we never drew a mark for — a curated brand mark always wins. */
  logoUrl?: string;
  /** How many tools the toolkit exposes, per the live catalog. */
  toolsCount?: number;
  /** Composio's toolkit slug when it differs from ours. Carried so the mount
   *  can be minted (and revoked) without a second lookup table. */
  toolkit?: string;
  /** The provider only accepts OUR OWN developer app (no managed auth) — a
   *  founder-gated "later", shown honestly rather than as generic rolling. */
  needsOurApp?: boolean;
}

/** Connectors that run on ThinkingRoot's own infrastructure, registered with
 *  every engine automatically — no account, no sign-in, nothing to connect.
 *  They were previously INVISIBLE here (the page rendered only the Composio
 *  catalog), which read as "missing" to anyone looking for them. */
export const BUILTIN_CONNECTORS: FullCatalogEntry[] = [
  {
    slug: "scrapling",
    name: "Scrapling",
    category: "Developer",
    auth: "none",
    tier: 1,
    status: "builtin",
  },
  // The hands (Wave 1). Registered per engine, NOT fleet-wide — the gallery
  // shows a built-in only when this project's engine actually mounts it
  // (`builtinSlugs`), so a project without the hand never sees a label that
  // promises one.
  {
    slug: "browser",
    name: "Browser",
    category: "Developer",
    auth: "none",
    tier: 1,
    status: "builtin",
  },
  {
    slug: "exec",
    name: "Code & files",
    category: "Developer",
    auth: "none",
    tier: 1,
    status: "builtin",
  },
  {
    slug: "desktop",
    name: "Desktop",
    category: "Developer",
    auth: "none",
    tier: 1,
    status: "builtin",
  },
];

/** Connectors backed by a customer-held credential we test-and-store
 *  ourselves — no OAuth tab, no Composio mount, no MCP install. Unlike
 *  `BUILTIN_CONNECTORS` these DO need a connect action (there is a secret to
 *  collect), so `status: "database"` gets its own gallery branch and its own
 *  dialog (`PostgresConnectDialog`) rather than the Composio consent flow in
 *  `connectConnector.ts`. Connected state comes from
 *  `GET /db-connections`, never from the MCP-mount `connectedSlugs` set. */
export const DATABASE_CONNECTORS: FullCatalogEntry[] = [
  {
    slug: "postgres",
    name: "PostgreSQL",
    category: "Developer",
    auth: "none",
    tier: 1,
    status: "database",
  },
];

export const FULL_CONNECTOR_CATALOG: FullCatalogEntry[] = [
  ...BUILTIN_CONNECTORS,
  ...DATABASE_CONNECTORS,
  ...[...KNOWN_CONNECTORS]
    .sort((a, b) => (a.tier ?? 3) - (b.tier ?? 3) || a.name.localeCompare(b.name))
    .map((c) => ({
      ...c,
      status: isBacked(c.slug) ? ("live" as const) : ("rolling" as const),
    })),
];

export const FULL_CONNECTOR_CATEGORIES = Array.from(
  new Set(FULL_CONNECTOR_CATALOG.map((c) => c.category)),
);

/** Connectors that run on ThinkingRoot infrastructure — they wear our seal. */
export const FIRST_PARTY_CONNECTOR_SLUGS: ReadonlySet<string> = new Set(
  BUILTIN_CONNECTORS.map((c) => c.slug),
);

export function isFirstPartyConnector(slug: string): boolean {
  return FIRST_PARTY_CONNECTOR_SLUGS.has(slug);
}

/** @deprecated alias — catalog IS the production set now (no "show more"). */
export const PRODUCTION_CONNECTOR_SLUGS: ReadonlySet<string> = new Set(
  CONNECTOR_CATALOG.map((c) => c.slug),
);

export function isProductionConnector(slug: string): boolean {
  return PRODUCTION_CONNECTOR_SLUGS.has(slug);
}

export const PRODUCTION_CONNECTOR_CATALOG = CONNECTOR_CATALOG;

export const CONNECTOR_CATEGORIES = Array.from(
  new Set(CONNECTOR_CATALOG.map((c) => c.category)),
);

export const PRODUCTION_CONNECTOR_CATEGORIES = CONNECTOR_CATEGORIES;
