---
name: watch-competitors
description: Keep watch on competitors. Given their names or sites, research each one, watch the pricing, changelog and careers pages they really have, and write a short dated baseline with sources. Use when someone asks to watch, track or keep an eye on competitors, or to tell them when a competitor changes its prices, ships something or starts hiring.
---
# Watch competitors

The job has three parts for each competitor: know who they are, watch the
pages that change when they move, and write down where things stand today
so the next change has something to be compared with.

## 1. Research each one

For each competitor, start `company_researcher` with its name, its site if
the person gave one, and what the team sells (`recall` it first if you do
not know). Start them all at once, one each. If `company_researcher` is not
offered, use `read_site` on the competitor's own site yourself.

If you cannot tell which company the person means (two companies share the
name, or the site does not match), say so for that one and leave it out
instead of guessing.

## 2. Find the pages worth watching

Look for these three pages on the competitor's own site:

- pricing (plans, prices, what each plan includes),
- changelog or release notes (what they ship),
- careers or jobs (what they hire for, which says where they are going).

Only use an address you actually read in this job: a page `read_site` or
`read_url` opened, or a link on one of those pages. Never make up an
address, and never guess one from the usual pattern (`/pricing`,
`/changelog`). A competitor without one of these pages simply has fewer
pages watched; say which were not there.

## 3. Watch them

Call `watch_page` once for each page you found, with a `focus` that says
what matters on it: "prices and plans", "new features", "open roles".
If `watch_page` is not offered here, list the pages you would watch and say
in one line that watching is not turned on for this job.

## 4. Write the baseline

Start with today's date. Then, for each competitor, one short block:

`<Competitor> (<site>)`
`Pricing: <the plans and prices the page shows today>. [sN]`
`Shipping: <the latest one or two changes, with their dates>. [sN]`
`Hiring: <how many open roles and which kinds>. [sN]`
`Watching: <the pages you set a watch on>.`

Every fact carries the tag of the page it came from. Leave out a line you
could not read rather than filling it in. End with one line on anything
you could not find or check.

If `remember` is offered, save each competitor's baseline to the team's
context as one entry, with the date in it, so a later change can be read
against it.
