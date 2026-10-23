"use client";

import { useEffect, useState, type CSSProperties, type ReactNode } from "react";
import {
  connectorBrand,
  connectorLogoColoredCdn,
  connectorMarkExt,
  PNG_MARKS,
} from "@/lib/connectorLogos";
import {
  connectorMarkSrc,
  getCachedLogoStage,
  setCachedLogoStage,
  type LogoStage,
} from "@/lib/connectorLogoCache";
import { isFirstPartyConnector } from "@/lib/connectors-catalog";
import { ThinkingRootMark } from "@/components/ThinkingRootMark";

/**
 * Full-color PNG marks (favicons / proprietary assets). Prefer these as
 * `<img>` — never monochrome-mask them.
 *
 * The list itself lives in `lib/connectorLogos` so the idle prefetcher can
 * read it too: when only this component knew, `prefetchConnectorLogos`
 * warmed every slug as `.svg` and 404'd on each of these on every load.
 */
const FULL_COLOR_PNG = PNG_MARKS;

/**
 * Format / forge tiles that ship as intentional full-color SVGs.
 * Catalog brand SVGs are also treated as full-color via `initialStage`
 * (everything except ink/near-white brands).
 */
const FULL_COLOR_SVG = new Set([
  "pdf",
  "docx",
  "xlsx",
  "pptx",
  "gitlab",
  "bitbucket",
  // Multi-color marks whose catalog brand hex is near-black — still render
  // as authentic `<img>`, not a theme mask that flattens the glyph.
  "gmail",
  "google_drive",
  "google_calendar",
  "google_sheets",
  "google_meet",
  "google_analytics",
  "slack",
  // Notion's mark IS a white page + black N (not a decorative plate). Theme
  // masking the Simple Icons dump paints a solid white tile and kills the N.
  "notion",
  // Atlassian blue (#0052CC) sits on the ink-luma edge; the SVG is a full-bleed
  // rounded rect, so a mask reads as a white square. Keep authentic color.
  "trello",
  "aws",
  "azure_devops",
  "firecrawl",
  "opencode",
]);

/** Brand hexes that are essentially black (GitHub #181717, Resend, Close,
 *  Affinity, Exa …) mask to a near-invisible smudge on our dark panels.
 *  Luminance-test the brand colour rather than listing slugs — a new black-mark
 *  connector is then correct on arrival instead of one more patch. Below the
 *  threshold we hand the mark to the theme's foreground: white on dark, ink on
 *  light. Brands that ship full-bleed colored tiles (Trello) or a white-page
 *  glyph (Notion) must be listed in FULL_COLOR_SVG — luma alone is not enough. */
export function isInkBrandColor(hex: string): boolean {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return false;
  const n = parseInt(m[1], 16);
  // Rec. 601 luma — good enough to answer "is this basically black?".
  const luma =
    (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) /
    255;
  // 0.28 catches charcoal marks (Square #3E4348, CircleCI #343434) that still
  // vanish on dark panels while leaving real brand colors (navy, purple) alone.
  return luma < 0.28;
}

/** Near-white brand hexes (Cursor #FFF, Markdown #FFF) vanish as masks on
 *  light panels — same treatment as ink brands: follow `var(--text)`. */
export function isNearWhiteBrandColor(hex: string): boolean {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return false;
  const n = parseInt(m[1], 16);
  const luma =
    (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) /
    255;
  return luma > 0.85;
}

function maskColor(hex: string): string {
  return isInkBrandColor(hex) || isNearWhiteBrandColor(hex)
    ? "var(--text)"
    : hex;
}

/**
 * Local SVGs shipped with hard black fills (Simple Icons dumps). Rendering
 * them as `<img>` on a dark panel makes the mark vanish — force the theme
 * mask so they take `var(--text)` / brand color instead.
 */
const FORCE_THEME_MASK = new Set([
  "chatgpt",
  "codex",
  "vscode",
  "cursor",
  "github",
  "markdown",
  "raw", // Any MCP — official MCP mark, mono
  "cline",
  "windsurf",
]);

function initialStage(slug: string): LogoStage {
  const brand = connectorBrand(slug);
  // Nothing on disk for this slug — go straight to the CDN glyph (or the theme
  // letter for an ink brand, which a brand-colored CDN mark would render
  // black-on-black). Choosing a local stage here is what asked the server for
  // `neon.svg`, `exec.svg`, `desktop.svg`, `browser.svg` and `scrapling.svg` on
  // every single page load, none of which have ever existed.
  if (!connectorMarkExt(slug)) {
    return isInkBrandColor(brand.color) ? "fallback" : "cdn";
  }
  if (FORCE_THEME_MASK.has(slug)) return "mask";
  if (FULL_COLOR_PNG.has(slug)) return "png";
  if (FULL_COLOR_SVG.has(slug)) return "svg";
  // Pure ink/near-white mono marks → theme mask so they stay visible on both
  // panels. Multi-color authentic SVGs (Gmail, Slack, …) render as `<img>`.
  if (isInkBrandColor(brand.color) || isNearWhiteBrandColor(brand.color)) {
    return "mask";
  }
  return "svg";
}

function resolveStage(slug: string): LogoStage {
  return getCachedLogoStage(slug) ?? initialStage(slug);
}

/**
 * Paint a monochrome SVG with the theme foreground. Used for ink brands
 * (GitHub, …) and for Memories origin marks that would otherwise ship
 * as a raw black `<img>` on a dark panel.
 *
 * `mask-mode: alpha` is required: WebKit's default luminance mode treats a
 * black Simple Icons path as a transparent hole, so the mark vanishes (or
 * composites into a black smudge) instead of taking `background-color`.
 *
 * Do NOT mask Cursor through this — CSS `mask-image` rasterizes its
 * compound-path hole shut and the tile reads as a solid hexagon. Use
 * `CursorInkMark` (inline SVG + currentColor) instead.
 */
export function ThemeInkMark({
  src,
  size,
  color = "var(--text)",
  className = "",
}: {
  src: string;
  size: number;
  color?: string;
  className?: string;
}) {
  return (
    <span
      className={`inline-block shrink-0 ${className}`}
      style={
        {
          width: size,
          height: size,
          backgroundColor: color,
          WebkitMaskImage: `url(${src})`,
          maskImage: `url(${src})`,
          WebkitMaskSize: "contain",
          maskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
          maskRepeat: "no-repeat",
          WebkitMaskPosition: "center",
          maskPosition: "center",
          // Not in CSStype Properties yet; required so black Simple Icons
          // paths are opaque holes for background-color, not luminance voids.
          WebkitMaskMode: "alpha",
          maskMode: "alpha",
        } as CSSProperties
      }
      aria-hidden
    />
  );
}

/** Official Cursor mark — hexagon with the facet cut. Inline so the hole
 *  survives (CSS mask-image collapses it to a solid slab). */
function CursorInkMark({
  size,
  color = "var(--text)",
  className = "",
}: {
  size: number;
  color?: string;
  className?: string;
}) {
  return (
    <svg
      className={`shrink-0 ${className}`}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden
    >
      <path
        fill={color}
        fillRule="evenodd"
        clipRule="evenodd"
        d="M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
      />
    </svg>
  );
}

/** Official PostgreSQL "Slonik" elephant mark, inlined so this one connector
 *  tile never depends on a network fetch (CDN or local `/connectors/*.svg`
 *  asset) for its own logo — it ships as JS, not as a request. Single-fill
 *  path, so it stays monochrome-friendly and reads on both panel themes. */
function PostgresElephantMark({
  size,
  color = "#4169E1",
  className = "",
}: {
  size: number;
  color?: string;
  className?: string;
}) {
  return (
    <svg
      className={`shrink-0 ${className}`}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden
    >
      <path
        fill={color}
        d="M23.5594 14.7228a.5269.5269 0 0 0-.0563-.1191c-.139-.2632-.4768-.3418-1.0074-.2321-1.6533.3411-2.2935.1312-2.5256-.0191 1.342-2.0482 2.445-4.522 3.0411-6.8297.2714-1.0507.7982-3.5237.1222-4.7316a1.5641 1.5641 0 0 0-.1509-.235C21.6931.9086 19.8007.0248 17.5099.0005c-1.4947-.0158-2.7705.3461-3.1161.4794a9.449 9.449 0 0 0-.5159-.0816 8.044 8.044 0 0 0-1.3114-.1278c-1.1822-.0184-2.2038.2642-3.0498.8406-.8573-.3211-4.7888-1.645-7.2219.0788C.9359 2.1526.3086 3.8733.4302 6.3043c.0409.818.5069 3.334 1.2423 5.7436.4598 1.5065.9387 2.7019 1.4334 3.582.553.9942 1.1259 1.5933 1.7143 1.7895.4474.1491 1.1327.1441 1.8581-.7279.8012-.9635 1.5903-1.8258 1.9446-2.2069.4351.2355.9064.3625 1.39.3772a.0569.0569 0 0 0 .0004.0041 11.0312 11.0312 0 0 0-.2472.3054c-.3389.4302-.4094.5197-1.5002.7443-.3102.064-1.1344.2339-1.1464.8115-.0025.1224.0329.2309.0919.3268.2269.4231.9216.6097 1.015.6331 1.3345.3335 2.5044.092 3.3714-.6787-.017 2.231.0775 4.4174.3454 5.0874.2212.5529.7618 1.9045 2.4692 1.9043.2505 0 .5263-.0291.8296-.0941 1.7819-.3821 2.5557-1.1696 2.855-2.9059.1503-.8707.4016-2.8753.5388-4.1012.0169-.0703.0357-.1207.057-.1362.0007-.0005.0697-.0471.4272.0307a.3673.3673 0 0 0 .0443.0068l.2539.0223.0149.001c.8468.0384 1.9114-.1426 2.5312-.4308.6438-.2988 1.8057-1.0323 1.5951-1.6698zM2.371 11.8765c-.7435-2.4358-1.1779-4.8851-1.2123-5.5719-.1086-2.1714.4171-3.6829 1.5623-4.4927 1.8367-1.2986 4.8398-.5408 6.108-.13-.0032.0032-.0066.0061-.0098.0094-2.0238 2.044-1.9758 5.536-1.9708 5.7495-.0002.0823.0066.1989.0162.3593.0348.5873.0996 1.6804-.0735 2.9184-.1609 1.1504.1937 2.2764.9728 3.0892.0806.0841.1648.1631.2518.2374-.3468.3714-1.1004 1.1926-1.9025 2.1576-.5677.6825-.9597.5517-1.0886.5087-.3919-.1307-.813-.5871-1.2381-1.3223-.4796-.839-.9635-2.0317-1.4155-3.5126zm6.0072 5.0871c-.1711-.0428-.3271-.1132-.4322-.1772.0889-.0394.2374-.0902.4833-.1409 1.2833-.2641 1.4815-.4506 1.9143-1.0002.0992-.126.2116-.2687.3673-.4426a.3549.3549 0 0 0 .0737-.1298c.1708-.1513.2724-.1099.4369-.0417.156.0646.3078.26.3695.4752.0291.1016.0619.2945-.0452.4444-.9043 1.2658-2.2216 1.2494-3.1676 1.0128zm2.094-3.988-.0525.141c-.133.3566-.2567.6881-.3334 1.003-.6674-.0021-1.3168-.2872-1.8105-.8024-.6279-.6551-.9131-1.5664-.7825-2.5004.1828-1.3079.1153-2.4468.079-3.0586-.005-.0857-.0095-.1607-.0122-.2199.2957-.2621 1.6659-.9962 2.6429-.7724.4459.1022.7176.4057.8305.928.5846 2.7038.0774 3.8307-.3302 4.7363-.084.1866-.1633.3629-.2311.5454zm7.3637 4.5725c-.0169.1768-.0358.376-.0618.5959l-.146.4383a.3547.3547 0 0 0-.0182.1077c-.0059.4747-.054.6489-.115.8693-.0634.2292-.1353.4891-.1794 1.0575-.11 1.4143-.8782 2.2267-2.4172 2.5565-1.5155.3251-1.7843-.4968-2.0212-1.2217a6.5824 6.5824 0 0 0-.0769-.2266c-.2154-.5858-.1911-1.4119-.1574-2.5551.0165-.5612-.0249-1.9013-.3302-2.6462.0044-.2932.0106-.5909.019-.8918a.3529.3529 0 0 0-.0153-.1126 1.4927 1.4927 0 0 0-.0439-.208c-.1226-.4283-.4213-.7866-.7797-.9351-.1424-.059-.4038-.1672-.7178-.0869.067-.276.1831-.5875.309-.9249l.0529-.142c.0595-.16.134-.3257.213-.5012.4265-.9476 1.0106-2.2453.3766-5.1772-.2374-1.0981-1.0304-1.6343-2.2324-1.5098-.7207.0746-1.3799.3654-1.7088.5321a5.6716 5.6716 0 0 0-.1958.1041c.0918-1.1064.4386-3.1741 1.7357-4.4823a4.0306 4.0306 0 0 1 .3033-.276.3532.3532 0 0 0 .1447-.0644c.7524-.5706 1.6945-.8506 2.802-.8325.4091.0067.8017.0339 1.1742.081 1.939.3544 3.2439 1.4468 4.0359 2.3827.8143.9623 1.2552 1.9315 1.4312 2.4543-1.3232-.1346-2.2234.1268-2.6797.779-.9926 1.4189.543 4.1729 1.2811 5.4964.1353.2426.2522.4522.2889.5413.2403.5825.5515.9713.7787 1.2552.0696.087.1372.1714.1885.245-.4008.1155-1.1208.3825-1.0552 1.717-.0123.1563-.0423.4469-.0834.8148-.0461.2077-.0702.4603-.0994.7662zm.8905-1.6211c-.0405-.8316.2691-.9185.5967-1.0105a2.8566 2.8566 0 0 0 .135-.0406 1.202 1.202 0 0 0 .1342.103c.5703.3765 1.5823.4213 3.0068.1344-.2016.1769-.5189.3994-.9533.6011-.4098.1903-1.0957.333-1.7473.3636-.7197.0336-1.0859-.0807-1.1721-.151zm.5695-9.2712c-.0059.3508-.0542.6692-.1054 1.0017-.055.3576-.112.7274-.1264 1.1762-.0142.4368.0404.8909.0932 1.3301.1066.887.216 1.8003-.2075 2.7014a3.5272 3.5272 0 0 1-.1876-.3856c-.0527-.1276-.1669-.3326-.3251-.6162-.6156-1.1041-2.0574-3.6896-1.3193-4.7446.3795-.5427 1.3408-.5661 2.1781-.463zm.2284 7.0137a12.3762 12.3762 0 0 0-.0853-.1074l-.0355-.0444c.7262-1.1995.5842-2.3862.4578-3.4385-.0519-.4318-.1009-.8396-.0885-1.2226.0129-.4061.0666-.7543.1185-1.0911.0639-.415.1288-.8443.1109-1.3505.0134-.0531.0188-.1158.0118-.1902-.0457-.4855-.5999-1.938-1.7294-3.253-.6076-.7073-1.4896-1.4972-2.6889-2.0395.5251-.1066 1.2328-.2035 2.0244-.1859 2.0515.0456 3.6746.8135 4.8242 2.2824a.908.908 0 0 1 .0667.1002c.7231 1.3556-.2762 6.2751-2.9867 10.5405zm-8.8166-6.1162c-.025.1794-.3089.4225-.6211.4225a.5821.5821 0 0 1-.0809-.0056c-.1873-.026-.3765-.144-.5059-.3156-.0458-.0605-.1203-.178-.1055-.2844.0055-.0401.0261-.0985.0925-.1488.1182-.0894.3518-.1226.6096-.0867.3163.0441.6426.1938.6113.4186zm7.9305-.4114c.0111.0792-.049.201-.1531.3102-.0683.0717-.212.1961-.4079.2232a.5456.5456 0 0 1-.075.0052c-.2935 0-.5414-.2344-.5607-.3717-.024-.1765.2641-.3106.5611-.352.297-.0414.6111.0088.6356.1851z"
      />
    </svg>
  );
}

export function ConnectorLogo({
  slug,
  name,
  size = 52,
  className = "",
  variant = "tile",
}: {
  slug: string;
  name: string;
  size?: number;
  className?: string;
  /** `tile` = fixed slot + optical inset so every mark reads the same size. */
  variant?: "tile" | "full";
}) {
  const [stage, setStage] = useState<LogoStage>(() => resolveStage(slug));

  useEffect(() => {
    setStage(resolveStage(slug));
  }, [slug]);

  const brand = connectorBrand(slug);
  const ink = isInkBrandColor(brand.color);

  const commitStage = (next: LogoStage) => {
    setCachedLogoStage(slug, next);
    setStage(next);
  };

  useEffect(() => {
    if (stage !== "mask") return;
    let cancelled = false;
    const img = new Image();
    img.onload = () => {
      if (!cancelled) setCachedLogoStage(slug, "mask");
    };
    img.onerror = () => {
      // Ink brands must NOT fall through to a brand-colored CDN glyph
      // (`…/notion/000000`) — that is the black-on-black bug. Prefer the
      // theme-ink letter fallback over a wrong-color mark.
      if (cancelled) return;
      const next = ink ? "fallback" : "cdn";
      setCachedLogoStage(slug, next);
      setStage(next);
    };
    img.src = connectorMarkSrc(slug, "svg");
    return () => {
      cancelled = true;
    };
  }, [stage, slug, ink]);

  const dim = Math.round(size);
  const isFullCardMark =
    stage === "png" || stage === "svg" || FULL_COLOR_PNG.has(slug) || FULL_COLOR_SVG.has(slug);
  const glyph = variant === "tile" ? Math.round(dim * (isFullCardMark ? 0.92 : 0.78)) : dim;
  const initial = name.trim().charAt(0).toUpperCase() || "?";
  // Claude's Simple Icons mark is alpha-heavy to the right/down — a geometric
  // center reads as top-left. Nudge the glyph so it sits optically centered.
  const opticalShift =
    slug === "claude_code" || slug === "claude_desktop" || slug === "claude"
      ? "translate(-3.2%, -0.6%)"
      : undefined;

  const slot = (inner: ReactNode) => (
    <div
      className={`flex items-center justify-center shrink-0 overflow-hidden ${className}`}
      style={{ width: dim, height: dim, background: "transparent" }}
      title={name}
    >
      {opticalShift ? (
        <span
          className="flex items-center justify-center"
          style={{ transform: opticalShift }}
        >
          {inner}
        </span>
      ) : (
        inner
      )}
    </div>
  );

  // Inline, self-contained mark — bypasses the fetch/CDN/mask pipeline below
  // entirely, same as CursorInkMark's hole-preserving special case.
  if (slug === "postgres") {
    return slot(<PostgresElephantMark size={glyph} />);
  }

  // Built-ins are ours — the HQ seal, never a letter tile or a borrowed brand.
  if (isFirstPartyConnector(slug)) {
    return slot(
      <span className="block" style={{ width: glyph, height: glyph }}>
        <ThinkingRootMark className="w-full h-full" interactive={false} />
      </span>,
    );
  }

  if (stage === "fallback") {
    return slot(
      <span className="text-[13px] font-semibold text-[var(--muted)]">{initial}</span>,
    );
  }

  if (stage === "mask") {
    const inkColor = maskColor(brand.color);
    // Cursor's hole dies under CSS mask-image — paint the path inline.
    if (slug === "cursor") {
      return slot(<CursorInkMark size={glyph} color={inkColor} />);
    }
    return slot(
      <ThemeInkMark
        src={connectorMarkSrc(slug, "svg")}
        size={glyph}
        color={inkColor}
      />,
    );
  }

  const src =
    stage === "png"
      ? connectorMarkSrc(slug, "png")
      : stage === "svg"
        ? connectorMarkSrc(slug, "svg")
        : connectorLogoColoredCdn(slug);

  return slot(
    <img
      src={src}
      alt=""
      width={glyph * 2}
      height={glyph * 2}
      decoding="async"
      className="max-w-full max-h-full object-contain"
      style={{ width: glyph, height: glyph, background: "transparent" }}
      draggable={false}
      onLoad={() => setCachedLogoStage(slug, stage)}
      onError={() => {
        const next =
          stage === "svg"
            ? FULL_COLOR_PNG.has(slug)
              ? "png"
              : ink
                ? "mask"
                : "cdn"
            : stage === "png"
              ? ink
                ? "mask"
                : "cdn"
              : "fallback";
        commitStage(next);
      }}
    />,
  );
}
