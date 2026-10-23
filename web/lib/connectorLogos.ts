import { CONNECTOR_MARKS, type MarkExt } from "./connectorMarks.generated";

/** Maps catalog slugs → Simple Icons id + brand hex for logo tiles. */

export const CONNECTOR_ICON: Record<string, { icon: string; color: string }> = {
  // Business expansion (2026-08-30) — authentic vendor SVGs live in
  // public/connectors/<slug>.svg (preferred); these are tile colors + fallback.
  basecamp: { icon: "basecamp", color: "#1D2D35" },
  todoist: { icon: "todoist", color: "#E44332" },
  dynamics365: { icon: "dynamics365", color: "#0B53CE" },
  facebook: { icon: "facebook", color: "#0866FF" },
  pinterest: { icon: "pinterest", color: "#BD081C" },
  sendgrid: { icon: "sendgrid", color: "#1A82E2" },
  amplitude: { icon: "amplitude", color: "#1E61F0" },
  segment: { icon: "segment", color: "#52BD94" },
  gorgias: { icon: "gorgias", color: "#7A69F5" },
  zoho_desk: { icon: "zoho", color: "#E42527" },
  crisp: { icon: "crisp", color: "#1972F5" },
  freshbooks: { icon: "freshbooks", color: "#0075DD" },
  zoho_books: { icon: "zoho", color: "#E42527" },
  zoho_invoice: { icon: "zoho", color: "#E42527" },
  recurly: { icon: "recurly", color: "#6F42C1" },
  maxio: { icon: "maxio", color: "#0C2A46" },
  pandadoc: { icon: "pandadoc", color: "#23B26D" },
  render: { icon: "render", color: "#000000" },
  jumpcloud: { icon: "jumpcloud", color: "#14A19A" },
  gmail: { icon: "gmail", color: "#EA4335" },
  outlook: { icon: "microsoftoutlook", color: "#0078D4" },
  slack: { icon: "slack", color: "#4A154B" },
  discord: { icon: "discord", color: "#5865F2" },
  microsoft_teams: { icon: "microsoftteams", color: "#6264A7" },
  msteams: { icon: "microsoftteams", color: "#6264A7" },
  whatsapp: { icon: "whatsapp", color: "#25D366" },
  twilio: { icon: "twilio", color: "#F22F46" },
  resend: { icon: "resend", color: "#000000" },
  intercom: { icon: "intercom", color: "#6AFDEF" },
  freshdesk: { icon: "freshdesk", color: "#25C16F" },
  front: { icon: "front", color: "#001B38" },
  notion: { icon: "notion", color: "#000000" },
  google_calendar: { icon: "googlecalendar", color: "#4285F4" },
  google_docs: { icon: "googledocs", color: "#4285F4" },
  google_drive: { icon: "googledrive", color: "#4285F4" },
  google_sheets: { icon: "googlesheets", color: "#34A853" },
  google_slides: { icon: "googleslides", color: "#FBBC04" },
  google_meet: { icon: "googlemeet", color: "#00897B" },
  google_analytics: { icon: "googleanalytics", color: "#E37400" },
  onedrive: { icon: "microsoftonedrive", color: "#0078D4" },
  sharepoint: { icon: "microsoftsharepoint", color: "#038387" },
  dropbox: { icon: "dropbox", color: "#0061FF" },
  confluence: { icon: "confluence", color: "#172B4D" },
  trello: { icon: "trello", color: "#0052CC" },
  monday: { icon: "mondaydotcom", color: "#F62B54" },
  calendly: { icon: "calendly", color: "#006BFF" },
  cal_com: { icon: "caldotcom", color: "#292929" },
  salesforce: { icon: "salesforce", color: "#00A1E0" },
  hubspot: { icon: "hubspot", color: "#FF7A59" },
  attio: { icon: "attio", color: "#5046E5" },
  // Close CRM — NOT simple-icons "close" (that's a generic X).
  close: { icon: "close", color: "#1C2B36" },
  affinity: { icon: "affinity", color: "#222222" },
  gong: { icon: "gong", color: "#8039DF" },
  github: { icon: "github", color: "#181717" },
  gitlab: { icon: "gitlab", color: "#FC6D26" },
  bitbucket: { icon: "bitbucket", color: "#0052CC" },
  jira: { icon: "jira", color: "#0052CC" },
  linear: { icon: "linear", color: "#5E6AD2" },
  asana: { icon: "asana", color: "#F06A6A" },
  clickup: { icon: "clickup", color: "#7B68EE" },
  aws: { icon: "amazonwebservices", color: "#FF9900" },
  azure_devops: { icon: "azuredevops", color: "#0078D7" },
  supabase: { icon: "supabase", color: "#3FCF8E" },
  neon: { icon: "neon", color: "#34D59A" },
  postgres: { icon: "postgresql", color: "#4169E1" },
  mongodb: { icon: "mongodb", color: "#47A248" },
  figma: { icon: "figma", color: "#F24E1E" },
  miro: { icon: "miro", color: "#FFD02F" },
  canva: { icon: "canva", color: "#00C4CC" },
  exa: { icon: "exa", color: "#1A1A1A" },
  tavily: { icon: "tavily", color: "#0056D2" },
  perplexity_ai: { icon: "perplexity", color: "#1FB8CD" },
  brave_search: { icon: "brave", color: "#FB542B" },
  firecrawl: { icon: "firecrawl", color: "#FF4D00" },
  fireflies: { icon: "fireflies", color: "#8250E0" },
  hacker_news: { icon: "ycombinator", color: "#F26522" },
  reddit: { icon: "reddit", color: "#FF4500" },
  reddit_search: { icon: "reddit", color: "#FF4500" },
  google_maps: { icon: "googlemaps", color: "#4285F4" },
  shopify: { icon: "shopify", color: "#7AB55C" },
  woocommerce: { icon: "woocommerce", color: "#96588A" },
  quickbooks: { icon: "quickbooks", color: "#2CA01C" },
  chargebee: { icon: "chargebee", color: "#FF4785" },
  moneybird: { icon: "moneybird", color: "#0073E6" },
  coinbase: { icon: "coinbase", color: "#0052FF" },
  yahoo_finance: { icon: "yahoo", color: "#6001D2" },
  mixpanel: { icon: "mixpanel", color: "#7856FF" },
  posthog: { icon: "posthog", color: "#F9BD2B" },
  airtable: { icon: "airtable", color: "#18BFFF" },
  stripe: { icon: "stripe", color: "#635BFF" },
  square: { icon: "square", color: "#3E4348" },
  mem0: { icon: "mem0", color: "#6366F1" },
  hugging_face: { icon: "huggingface", color: "#FFD21E" },
  openrouter: { icon: "openrouter", color: "#0F172A" },
  wordpress: { icon: "wordpress", color: "#21759B" },
  linkedin: { icon: "linkedin", color: "#0A66C2" },
  mailchimp: { icon: "mailchimp", color: "#FFE01B" },
  youtube: { icon: "youtube", color: "#FF0000" },
  instagram: { icon: "instagram", color: "#E4405F" },
  spotify: { icon: "spotify", color: "#1DB954" },
  heygen: { icon: "heygen", color: "#6C5CE7" },
  zoom: { icon: "zoom", color: "#0B5CFF" },
  zendesk: { icon: "zendesk", color: "#03363D" },
  pipedrive: { icon: "pipedrive", color: "#017737" },
  zoho_crm: { icon: "zoho", color: "#C8202B" },
  apollo: { icon: "apollo", color: "#000000" },
  ashby: { icon: "ashby", color: "#6E5BFF" },
  bamboohr: { icon: "bamboohr", color: "#73C41D" },
  greenhouse: { icon: "greenhouse", color: "#24A47F" },
  rippling: { icon: "rippling", color: "#FF5A36" },
  jotform: { icon: "jotform", color: "#FF6100" },
  typeform: { icon: "typeform", color: "#262627" },
  webflow: { icon: "webflow", color: "#4353FF" },
  // Official Simple Icons orange — brand purple #362D59 vanishes on dark UI.
  sentry: { icon: "sentry", color: "#FB4226" },
  pagerduty: { icon: "pagerduty", color: "#06AC38" },
  datadog: { icon: "datadog", color: "#632CA6" },
  circleci: { icon: "circleci", color: "#343434" },
  vercel: { icon: "vercel", color: "#000000" },
  cloudflare: { icon: "cloudflare", color: "#F38020" },
  postman: { icon: "postman", color: "#FF6C37" },
  databricks: { icon: "databricks", color: "#FF3621" },
  coda: { icon: "coda", color: "#F46A54" },
  box: { icon: "box", color: "#0061D5" },
  guru: { icon: "guru", color: "#4A90E2" },
  telegram: { icon: "telegram", color: "#26A5E4" },
  servicenow: { icon: "servicenow", color: "#62D84E" },
  // AI clients (MCP & Agents). Local SVGs/PNGs in public/connectors/ preferred;
  // CDN ids are fallbacks when the local asset is missing.
  claude_code: { icon: "claude", color: "#D97757" },
  claude_desktop: { icon: "claude", color: "#D97757" },
  cursor: { icon: "cursor", color: "#FFFFFF" },
  vscode: { icon: "visualstudiocode", color: "#007ACC" },
  chatgpt: { icon: "openai", color: "#10A37F" },
  codex: { icon: "openai", color: "#10A37F" },
  gemini_cli: { icon: "googlegemini", color: "#8E75B2" },
  hermes: { icon: "hermes", color: "#5B6CFF" },
  openclaw: { icon: "openclaw", color: "#FF4D1A" },
  opencode: { icon: "opencode", color: "#F1ECEC" },
  antigravity: { icon: "antigravity", color: "#4285F4" },
  cline: { icon: "cline", color: "#18181B" },
  windsurf: { icon: "windsurf", color: "#111111" },
  // Official MCP mark — ink on light, theme foreground on dark via mask.
  raw: { icon: "modelcontextprotocol", color: "#111111" },
  // Knowledge formats (Home “Add knowledge” stack)
  pdf: { icon: "adobeacrobatreader", color: "#E5252A" },
  docx: { icon: "microsoftword", color: "#185ABD" },
  xlsx: { icon: "microsoftexcel", color: "#107C41" },
  pptx: { icon: "microsoftpowerpoint", color: "#C43E1C" },
  markdown: { icon: "markdown", color: "#FFFFFF" },
  html5: { icon: "html5", color: "#E34F26" },
  json: { icon: "json", color: "#000000" },
  image: { icon: "image", color: "#A78BFA" },
  audio: { icon: "audio", color: "#2DD4BF" },
  // First-party built-ins — ThinkingRoot seal, not a third-party brand.
  scrapling: { icon: "thinkingroot", color: "#111111" },
  browser: { icon: "thinkingroot", color: "#111111" },
  exec: { icon: "thinkingroot", color: "#111111" },
  desktop: { icon: "thinkingroot", color: "#111111" },
};

export function connectorBrand(slug: string) {
  return CONNECTOR_ICON[slug] ?? { icon: slug.replace(/_/g, ""), color: "#4A8FAE" };
}

/**
 * Which local mark each slug ships, READ FROM DISK at build time
 * (`scripts/gen-connector-marks.mjs` → `connectorMarks.generated.ts`).
 *
 * This was a hand-maintained list and it drifted four separate ways, each one a
 * 404 on every page load that nothing failed on: shipped PNG but declared SVG
 * (rippling, servicenow); declared PNG but ships SVG (greenhouse); declared but
 * ships nothing (neon); no asset at all yet still fetched (exec, desktop,
 * browser, scrapling). A list a person edits drifts again — the directory
 * cannot. Adding or deleting a file is now the whole change.
 */
export const PNG_MARKS: ReadonlySet<string> = new Set(
  Object.entries(CONNECTOR_MARKS)
    .filter(([, ext]) => ext === "png")
    .map(([slug]) => slug),
);

/**
 * The extension this slug's local mark ships as, or `null` when it has none.
 *
 * `null` is load-bearing: the caller must NOT fetch. A slug with no local mark
 * has an inline mark (first-party) or a CDN glyph, and asking for a file that
 * was never there costs one 404 per page load and warms nothing.
 */
export function connectorMarkExt(slug: string): MarkExt | null {
  return CONNECTOR_MARKS[slug] ?? null;
}

/** Local mark (preferred) → Simple Icons CDN fallback. */
export function connectorLogoUrl(slug: string): string | null {
  const ext = connectorMarkExt(slug);
  return ext && `/connectors/${slug}.${ext}`;
}

export function connectorLogoCdn(slug: string): string {
  const { icon } = connectorBrand(slug);
  return `https://cdn.simpleicons.org/${icon}/white`;
}

/** Brand-colored glyph on a transparent background (no tile). */
export function connectorLogoColoredCdn(slug: string): string {
  const { icon, color } = connectorBrand(slug);
  return `https://cdn.simpleicons.org/${icon}/${color.replace("#", "")}`;
}
