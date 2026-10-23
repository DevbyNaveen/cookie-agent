---
name: web-page
description: Make a single shareable web page (report, one-pager, event page, explainer, simple tool) as an HTML file, clean on phone and desktop, content from real sources.
---
# Web page

Use for "make a page for…", "turn this into a web page", a shareable one-pager. For a product marketing page with a CTA, use landing-page.

## Ask only if missing
- What the page is for and who opens it.
- Content source (notes, a document, research) and any brand colors.

## Procedure
1. Gather content: `recall`, `read_document`, `connector_call`, or research with sources (`web_search`, `fetch_page`, `check_quote` for quotes).
2. Decide the structure: title, one-line summary, sections in the order the reader needs them. A table or chart where it beats prose.
3. Design rules: one column on phones, readable body text (16px+), clear headings, sufficient contrast, light and dark readable, real alt text, no horizontal scroll, no external trackers or ads.
4. If the page is for the person's customers: "context", not "memory"; avoid grounded, verifiable, provenance, citations, audit.
5. Build with `make_page`. Sources go at the bottom as links when the page states facts from outside.
6. Tell the person where the file is. Hosting or sharing it is their decision.

## Output format
```text
Page: <title> — <file path>
Sections: <list>
Sources linked: <n>
```

## Quality bar
- Opens and makes sense on a phone in five seconds.
- Nothing decorative that slows the read.
- Every fact on it is one the person could defend.

## Never
- Invent content, numbers, logos or testimonials to fill space.
- Copy another site's text or design wholesale.
- Collect form data (emails, payments) unless asked, and never passwords or card numbers.
