---
name: prospect-list
description: Build a list of companies (and business contacts) that fit the person's ideal customer, each with the sourced reason it fits; delivered as a spreadsheet or CSV.
---
# Prospect list

Use for "find me 30 companies like X", "build a target list", "who should we go after in <market>".

## Ask only if missing
- Ideal customer: industry, size, region, and the trigger that makes them need us now. `recall` first; only ask what isn't there.
- How many. Default 25.
- Contacts too, or companies only. Default companies only.

## Procedure
1. `recall` the product, past wins, and existing customers (to exclude them).
2. Turn the profile into searchable signals: job postings for a role, a technology on their site, a funding event, a regulation that hits them, a launch.
3. Find candidates: if Apollo or a CRM is connected (`connector_actions`), use its search via `connector_call`; otherwise `web_search` for lists, directories, registries and the signals.
4. Qualify each candidate with `fetch_page` on their own site (and the signal's page): confirm industry, region, rough size, and the trigger. Drop any you can't confirm.
5. Exclude existing customers and open deals (`connector_call` CRM lookup).
6. Contacts (if asked): business role and work channel from the company site, Apollo or the CRM only. Note the source of every email address; never guess one.
7. Score fit simply: count of profile criteria met (e.g. 4/5), not an invented number.
8. Deliver with `make_spreadsheet` (or `make_csv` for import into a CRM). Show the top 10 in chat.

## Output format
Spreadsheet columns:
`Company | Website | Country | Size (source) | Why now (signal) | Signal URL | Fit (criteria met) | Contact name | Title | Contact source | Notes`

Chat summary:
```text
<n> companies fit (<m> checked, <k> dropped: <reasons>).
Top 10:
1. <Company> — <why now> — <URL>
```

## Quality bar
- Every row has a dated, sourced "why now". A list without triggers is a phone book.
- No duplicates; no current customers.
- Fewer good rows beat many weak ones: say "found 14 that truly fit" rather than padding to 25.

## Never
- Invent companies, sizes, contacts, emails or signals.
- Scrape personal social media or private individuals; contacts are business roles only.
- Add rows to the CRM or start outreach without a yes.
