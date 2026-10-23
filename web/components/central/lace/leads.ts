// Leads, read out of an answer. The `find-leads` skill answers one paragraph
// per company, in one shape:
//
//   <Company> (<site>) — <what it does>. <The signal, with its date>.
//   Fits because <reason>. Approach: <role>, through <contact page>.
//
// A paragraph is a lead only when it has that head AND names a fit or an
// approach, so ordinary prose with a site in brackets is never taken for one.
// Nothing here guesses: every field is a slice of what Cookie wrote, and each
// lead keeps its paragraph's index so its sources stay attached.
//
// Kept free of imports so `node --test` can load it as-is.

export type Lead = {
  company: string;
  site: string;
  what: string;
  signal: string;
  fits: string;
  approach: string;
  /** Index of its paragraph in the answer (blank-line split). */
  para: number;
};

const HEAD = /^(.{2,80}?)\s+\(((?:https?:\/\/)?(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:\/[^\s)]*)?)\)\s*[—–-]{1,2}\s*([\s\S]+)$/i;

/** The answer's paragraphs, split the way the gateway splits them. */
export function paragraphs(answer: string): string[] {
  return answer
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean);
}

function firstSentence(text: string): [string, string] {
  // A sentence ends at ". " before a capital or a digit — not at "Inc. ",
  // "e.g. " or a decimal point.
  const m = /^(.+?[a-z0-9)%”"’'])\.\s+(?=[A-Z0-9“"])/.exec(text);
  return m ? [m[1].trim(), text.slice(m[0].length).trim()] : [text.trim().replace(/\.$/, ""), ""];
}

export function parseLead(paragraph: string, para: number): Lead | null {
  const flat = paragraph.replace(/^\s*(?:\d+[.)]|[-•*])\s+/, "").replace(/\s+/g, " ").trim();
  const m = HEAD.exec(flat);
  if (!m) return null;
  const [, company, site, body] = m;
  const approachAt = body.search(/\bApproach:\s*/i);
  const fitsAt = body.search(/\bFits because\b/i);
  if (approachAt < 0 && fitsAt < 0) return null;
  const cutAt = [approachAt, fitsAt].filter((i) => i >= 0).reduce((a, b) => Math.min(a, b));
  const [what, signal] = firstSentence(body.slice(0, cutAt).trim());
  const fits =
    fitsAt < 0 ? "" : body.slice(fitsAt, approachAt > fitsAt ? approachAt : undefined).replace(/^Fits because\s*/i, "").trim().replace(/\.$/, "");
  const approach = approachAt < 0 ? "" : body.slice(approachAt).replace(/^Approach:\s*/i, "").trim().replace(/\.$/, "");
  return {
    company: company.replace(/^\*+|\*+$/g, "").trim(),
    site: site.replace(/^https?:\/\//, "").replace(/^www\./, "").replace(/\/$/, ""),
    what,
    signal: signal.replace(/\.$/, ""),
    fits,
    approach,
    para,
  };
}

/** The leads in an answer, and the paragraphs that are not leads (what was
 *  searched, what was left out). Fewer than two leads is not a list: none. */
export function parseLeads(answer: string): { leads: Lead[]; rest: string[] } {
  const paras = paragraphs(answer);
  const leads: Lead[] = [];
  const rest: string[] = [];
  paras.forEach((p, i) => {
    const lead = parseLead(p, i);
    if (lead) leads.push(lead);
    else rest.push(p);
  });
  return leads.length >= 2 ? { leads, rest } : { leads: [], rest: paras };
}
