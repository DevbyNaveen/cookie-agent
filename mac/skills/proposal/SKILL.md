---
name: proposal
description: Write a client proposal from the real discovery notes, CRM deal and pricing: their problem in their words, the scope, timeline, price and next step; delivered as a document.
---
# Proposal

Use for "write the proposal for X", "send them a quote", statement of work drafts.

## Ask only if missing
- Client and deal (confirm against the CRM if connected).
- Price and terms if not in `recall` or the CRM. Never choose a price yourself.

## Procedure
1. `recall` the client: discovery notes, stated problems, decision makers, budget signals, deadlines, promises made.
2. If connected, `connector_call` the CRM deal (amount, stage, contacts) and the mail search for the last threads; note record ids.
3. Pull the person's standard pricing, terms and past proposals from `recall` or a document they point to (`read_document`).
4. Write:
   - Their situation: the problem in the client's own words (from notes/threads), and what it costs them, only if they said so.
   - Outcome: what will be true when we're done, measurable where the client gave a measure.
   - Scope: in scope, out of scope (explicitly), assumptions.
   - Plan and timeline: phases with dates or durations.
   - Investment: price, payment terms, validity date, exactly as the person gave them.
   - Why us: real, relevant proof only.
   - Next step: one action with a date.
5. Customer-facing wording: "context", not "memory"; avoid grounded, verifiable, provenance, citations, audit.
6. Show the draft, then build with `make_document` (or `make_deck` if they present it).
7. Sending is a separate step: offer a cover email as a draft (follow-up-draft rules), sent only on a yes.

## Output format
```text
# Proposal for <Client> — <project>
Prepared for <names>, <date>. Valid until <date>.

1. Where you are today
2. What changes
3. Scope (in / out / assumptions)
4. Plan and timeline
5. Investment
6. Why us
7. Next step
```

## Quality bar
- The client recognises their own words in section 1.
- "Out of scope" is explicit; it prevents the most expensive arguments.
- Two pages unless the deal truly needs more.

## Never
- Invent a price, discount, deadline, guarantee, case study or client claim.
- Promise results the person hasn't committed to.
- Send it, or e-sign anything, without the person's yes.
