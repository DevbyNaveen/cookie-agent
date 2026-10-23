"use client";

/**
 * Console brand mark — exact woven-hex seal.
 * White on dark theme, black on light — both transparent PNGs, no square.
 * Same assets as favicon / dashboard (`/brand/thinkingroot-asterisk-*.png`).
 */
type Props = {
  className?: string;
  interactive?: boolean;
  /** Kept for API compat. */
  variant?: "badge" | "plain";
  spinMode?: "none" | "rhythmic" | "smooth";
  /** Force a seal for pages that aren't on `html[data-theme]` (marketing / login). */
  tone?: "auto" | "light" | "dark";
};

const MARK_WHITE = "/brand/thinkingroot-asterisk-white.png?v=17";
const MARK_BLACK = "/brand/thinkingroot-asterisk-black.png?v=17";

export function ThinkingRootMark({
  className = "w-7 h-7",
  interactive = true,
  variant: _variant = "badge",
  spinMode = "none",
  tone = "auto",
}: Props) {
  void _variant;

  const imgClass = [
    "block w-full h-full object-contain select-none pointer-events-none absolute inset-0",
    interactive && spinMode === "none"
      ? "transition-transform duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] group-hover/brand:rotate-[60deg] group-active/brand:rotate-[180deg] motion-reduce:transition-none"
      : "",
    spinMode === "rhythmic" ? "tr-mark-spin-rhythmic" : "",
    spinMode === "smooth" ? "tr-mark-spin-smooth" : "",
  ]
    .filter(Boolean)
    .join(" ");

  const shellClass = [
    className,
    "shrink-0 relative inline-flex items-center justify-center bg-transparent",
    interactive
      ? "group-hover/brand:scale-[1.03] transition-transform duration-300"
      : "",
  ]
    .filter(Boolean)
    .join(" ");

  if (tone === "light" || tone === "dark") {
    const src = tone === "light" ? MARK_BLACK : MARK_WHITE;
    return (
      <div className={shellClass} role="img" aria-label="Enkeon">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt="" draggable={false} className={imgClass} />
      </div>
    );
  }

  return (
    <div className={shellClass} role="img" aria-label="Enkeon">
      {/* Dark (default): white seal · Light: black seal */}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={MARK_WHITE}
        alt=""
        draggable={false}
        className={`${imgClass} tr-mark-on-dark`}
      />
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={MARK_BLACK}
        alt=""
        draggable={false}
        className={`${imgClass} tr-mark-on-light`}
      />
    </div>
  );
}
