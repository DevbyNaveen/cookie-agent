---
name: person-brief
description: Professional brief on a named business contact from their company's pages, official bios, public talks or articles, and the person's own CRM and email history only.
---
# Person brief

Use before meeting, emailing or hiring a specific professional contact.

## What this skill may use (say this if asked for more)
Allowed: the contact's company website and official bio, press releases, published articles, conference talks, podcasts they appeared on in a professional role, public registry entries for company officers, and what the person's own connected apps hold (CRM records, email and calendar history with them).
Not allowed: personal social media (Instagram, Facebook, TikTok, personal X/Twitter), family, home address, health, religion, politics, sexual orientation, ethnicity or any other sensitive trait, people-search or data-broker sites, and any private individual who is not acting in a professional role. If the person asks for these, decline that part in one sentence and continue with the allowed sources.

## Ask only if missing
- Full name + company (or their work email). Both are needed to avoid briefing the wrong person.
- Purpose of the contact (sales call, interview, partnership).

## Procedure
1. `recall` the name: past notes, meetings, promises.
2. If connected: `connector_actions`, then `connector_call` the CRM contact lookup and the mail/calendar search for threads and meetings with them. Note app + record id for each fact.
3. `web_search` "<name>" "<company>" plus: bio, talk, interview, article, podcast. Professional results only.
4. `fetch_pages` the company team page, official bio and up to 5 public talks/articles. Confirm identity (same company, same role) before using a source; if two people share the name and you can't tell them apart, say so and stop for that source.
5. `check_quote` any quote you will show.
6. Write the brief. Offer `remember` for the one-line summary.

## Output format
```text
# <Name> — <title>, <company> (<date>)
Identity confirmed by: <URL>

## Role
- <Current role, since when> <source>
- <Previous roles relevant to the purpose> <source>

## What they talk about publicly
- <Topic — where — date> <URL>

## Your history with them
- <Last email / meeting / CRM note, date> (<app>: <record>)
- Open promises: <who owes what> (<app>: <record>) | none found

## Good openers
- <One specific, sourced reason to talk to them now>

## Not found
- <items>
```

## Quality bar
- Short: one screen. Every line has a URL or an app record.
- Openers reference their public work, never their private life.

## Never
- Scrape or cite personal social media, guess age, family, health, beliefs or any sensitive trait.
- Brief a private individual (someone not acting in a business role).
- Merge two people with the same name.
- Invent a role, employer, date or quote.
