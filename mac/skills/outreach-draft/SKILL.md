---
name: outreach-draft
description: Write a first-touch email or LinkedIn message to a prospect: one specific observation, why it's relevant to them, one ask; saved as a draft, never sent without a yes.
---
# Outreach draft

Use when the person wants to reach someone new: cold email, intro request, partnership pitch.

## Ask only if missing
- Who (name + company, or email) and what we offer them, in one line.
- The ask: a call, a reply, an intro, a trial. Default: a 20-minute call.

## Procedure
1. `recall` our product, positioning, past outreach to this company, and the person's writing style.
2. Research the recipient with person-brief rules (professional public info only) and the company with company-brief rules. Find ONE specific, recent, sourced observation: a launch, a hire, a talk they gave, a post on their company blog, a job opening that implies a need.
3. If connected, `connector_call` the CRM/mail search to make sure we haven't already contacted them; if we have, switch to follow-up-draft.
4. Write the message:
   - Line 1: the observation (specific, theirs, dated if useful). Not a compliment.
   - Lines 2–3: why that makes us relevant, in their terms. One proof point only if it's real and we can show it (a named customer only if `recall` or the CRM confirms they agreed to be named).
   - Last line: one ask, easy to say yes to.
   - Under 120 words. Subject line under 6 words, lowercase is fine, no clickbait.
5. Disclosure: suggest a short line such as "Written with help from an AI assistant." Explain it's expected under the EU AI Act (Art. 50) for AI-generated text sent to people in some cases; the person decides whether and how to word it.
6. Show the draft, the source for the observation, and where the recipient address came from (e.g. "address from HubSpot contact 1234" or "from their company team page, URL"), since Cookie will mark it "Not typed by you".
7. On yes, save as a draft: `connector_actions` to find the Gmail/Outlook (or LinkedIn) draft action, then `connector_call`. A draft is not a send. Sending is a separate yes on Cookie's card.

## Output format
```text
To: <address> (source: <app record or URL>)
Subject: <subject>

<body, ≤120 words>

<signature>
[Suggested disclosure: Written with help from an AI assistant.]

Why this opener: <observation> — <URL>
```

## Quality bar
- Could only have been written to this one person. If the observation would fit 100 companies, find a better one.
- No "I hope this finds you well", no "quick question", no feature lists, no fake urgency.
- One ask. No attachments on a first touch.

## Never
- Send, or schedule a send, without the person's yes on the card.
- Invent a mutual connection, a customer, a result, a metric or a prior conversation.
- Use anything from their personal social media or private life.
- Guess an email address pattern and present it as known; say "guessed pattern, unverified" if the person insists.
