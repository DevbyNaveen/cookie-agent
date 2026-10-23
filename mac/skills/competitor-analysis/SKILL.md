---
name: competitor-analysis
description: Compare the person's product with named competitors on offer, pricing, positioning, customers and recent moves, every cell sourced, with where we win and where we lose.
---
# Competitor analysis

Use for "how do we compare to X", battlecards, pricing reviews, positioning work.

## Ask only if missing
- Competitors to cover (2–5). If none named, propose the 3–5 most cited alternatives you find and confirm.
- Purpose: sales battlecard, pricing decision, or positioning. Default: battlecard.

## Procedure
1. `recall` our product, pricing, positioning, and any past notes on these competitors (win/loss notes, deals lost to them).
2. For each competitor, `fetch_pages`: home, pricing, product/features, customers/case studies, changelog or newsroom, docs if relevant.
3. `web_search` for third-party evidence: reviews on established review sites, analyst mentions, funding, last 6 months of launches.
4. If a CRM is connected, `connector_call` for deals where this competitor appears (competitor field or notes): win/loss counts from real rows only.
5. Build the comparison. Each cell holds a fact and its source, or "not public".
6. `check_quote` any customer review quote before use.
7. Write "where we win / where we lose" from the evidence, labelled as inference.
8. Offer `make_spreadsheet` (the grid) or `make_document` (battlecard).

## Output format
```text
# <Us> vs <competitors> — <date>

## At a glance
| | Us | <A> | <B> |
|---|---|---|---|
| Who it's for | | <fact> [1] | |
| Pricing (entry / main tier) | | | |
| Key capabilities | | | |
| Notable customers (public) | | | |
| Recent moves (6 mo) | | | |

## Where we win
- <point> — evidence: [n]
## Where we lose
- <point> — evidence: [n]
## How to handle "<common objection>"
- <answer using only true claims about us>

## Our record against them (CRM)
<won n / lost n, from <CRM>, <period>> | no CRM data

## Sources
[1] <URL> (<date accessed>)
```

## Quality bar
- Honest about where we lose; a battlecard that only flatters us gets reps burned.
- Pricing shows the date checked; pricing pages change.
- Distinguish their claims ("their site says") from independent evidence.

## Never
- Invent a competitor's price, customer, feature gap or weakness.
- Write disparaging or unverifiable claims about a competitor for customer-facing use.
- Use leaked or non-public material.
