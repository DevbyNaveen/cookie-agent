---
name: gtm-plan
description: Go-to-market plan for a product or launch: who to sell to, the message, channels, a 30/60/90-day sequence, and the metrics to watch, built on the person's real data and sourced market facts.
---
# GTM plan

Use for "how do we launch X", "plan our go-to-market", "how do we get our first 10 customers".

## Ask only if missing
- Product and stage (pre-launch, first customers, scaling).
- Goal with a number and date ("10 paying teams by Jan 31"). If none, ask once; it shapes everything.
- Budget and team (who can do the work, hours per week).

## Procedure
1. `recall` product, pricing, customers so far, what's been tried, past results. These are the facts the plan stands on.
2. If connected, pull real numbers: CRM deals by source and stage, conversion so far (`connector_call`). Note record counts.
3. Market facts: `web_search` + `fetch_pages` for the segment size indicators, buyer roles, where buyers gather, and 2–3 comparable companies' go-to-market (their own pages, interviews). Source each.
4. Choose ONE primary segment and ONE primary channel, with the reason. Secondary ones are listed as later experiments.
5. Write the message: the pain in the buyer's words (from real customer notes or sourced interviews), what changes for them, proof we really have.
6. Sequence 30/60/90 days with weekly actions an owner can execute, each with a measurable output.
7. Metrics: leading (replies, meetings, trials) and lagging (paid), with targets derived from the goal and real conversion rates; where we have no rate yet, say "first measurement" instead of assuming one.
8. Risks and the cheapest test for each.
9. Offer `make_document` (plan) and `make_spreadsheet` (the weekly tracker).

## Output format
```text
# GTM plan — <product> — goal: <number by date>

## Starting point (facts)
- <current customers, pipeline, conversion> (<source>)

## Who we sell to first
<Segment, buyer role, why them now> (<sources>)

## The message
Pain: ... / What changes: ... / Proof: ... (only real proof)

## Channel
Primary: <channel> because <reason>. Later experiments: <list>

## 30 / 60 / 90 days
| Week | Action | Owner | Output |
|---|---|---|---|

## Numbers to watch
| Metric | Target | Based on |
|---|---|---|

## Risks and tests
- <risk> → <test>, <cost>, <decision rule>
```

## Quality bar
- Focus: one segment, one channel, one goal. A plan that does everything does nothing.
- Every target shows the arithmetic or says "first measurement".
- Actions are concrete enough to put in a calendar.

## Never
- Invent market sizes, conversion rates, customers or testimonials.
- Promise outcomes; targets are targets.
- Recommend spending money or posting publicly on the person's behalf without a yes.
