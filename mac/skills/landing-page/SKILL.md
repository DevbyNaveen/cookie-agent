---
name: landing-page
description: Write and build a landing page for a product or offer: headline, problem, how it works, proof, one call to action, as a real page file; only true claims.
---
# Landing page

Use for "make a landing page for X", a waitlist page, an offer page for a campaign.

## Ask only if missing
- What it is and who it's for (one line each).
- The single action the visitor should take (sign up, book a call, buy) and its link.
- Brand: colors/logo/fonts, or "keep it simple".

## Procedure
1. `recall` product facts, pricing, positioning, approved customer names and real results.
2. Gather proof: only real numbers, named customers who agreed, and quotes confirmed with `check_quote` (or given by the person with permission).
3. Write the copy:
   - Headline: the outcome for the reader, ≤ 10 words. Sub-headline: who it's for and how, ≤ 25 words.
   - Problem: 2–3 lines in the buyer's words.
   - How it works: 3 steps.
   - Proof: real logos/quotes/numbers, or omit the section.
   - Objections: 3–5 FAQ items with true answers (price, data handling, setup time).
   - One CTA, repeated at top and bottom.
4. Customer-facing wording: say "context", not "memory"; never use the words grounded, verifiable, provenance, citations or audit on the page.
5. Show the copy for approval before building.
6. Build with `make_page`: single page, mobile-first, readable type (16px+ body), strong contrast, real alt text, no external trackers unless asked.
7. Tell them where the file is. Publishing is their step; this skill makes the file.

## Output format
Copy review first:
```text
Headline: ...
Sub-headline: ...
Problem: ...
How it works: 1. ... 2. ... 3. ...
Proof: ... (source for each)
FAQ: ...
CTA: <label> → <link>
```
Then the page file from `make_page`.

## Quality bar
- Five-second test: a stranger can say what it is, who it's for, and what to click.
- One CTA. No carousels. No stock-photo filler.
- Every claim on the page is something the person could defend to a customer.

## Never
- Invent testimonials, logos, user counts, ratings or "as seen in".
- Use fake scarcity or countdowns.
- Publish or connect a domain on their behalf.
