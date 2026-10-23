---
name: deck
description: Build a slide deck (pitch, sales, board update, training) with one message per slide, real numbers and a clear story; as a .pptx or in Keynote/PowerPoint.
---
# Deck

Use for "make a deck", "slides for the board meeting", "pitch deck", "turn this doc into slides".

## Ask only if missing
- Audience, the decision or action you want from them, and time slot (sets slide count: ~1 slide per 2 minutes).
- Source material and brand (template, colors) if any.

## Procedure
1. Gather facts: `recall`, `read_document` / `read_spreadsheet` for their files, `connector_call` for CRM numbers, `web_search` + `fetch_page` for market facts (sourced).
2. Write the storyline as slide titles only, before any design. Each title is a full-sentence takeaway ("Churn fell to 2% after onboarding changes"), not a topic ("Churn"). Show the titles for approval.
   - Pitch: problem → why now → product → proof → market → business model → team → ask.
   - Board/update: headline numbers → what went well → what didn't → decisions needed → next period.
   - Sales: their situation → cost of staying → what changes → proof → plan → next step.
3. For each slide: one message, one visual (chart, table, or ≤ 3 short bullets), speaker notes with the details.
4. Charts: from real data only; label units and dates; the source in small text on the slide.
5. Customer-facing decks: "context", not "memory"; avoid grounded, verifiable, provenance, citations, audit.
6. Build with `make_deck`. In Keynote/PowerPoint instead: `start_task` with plan + app, then `run_script`; `look` to check.

## Output format
```text
Storyline (<n> slides, ~<minutes> min):
1. <Takeaway title>
2. ...
Then: <file path>, with speaker notes on every slide and sources on slides with numbers.
```

## Quality bar
- Reading only the titles tells the whole story.
- ≤ 30 words of slide text per slide; details live in the notes.
- Every number on a slide can be traced to its source in the notes.

## Never
- Invent metrics, customers, logos, market sizes or projections presented as facts. Projections are labelled "projection" with their assumptions.
- Use a chart that distorts (truncated axis without saying so, 3D pies).
- Present or share the deck on the person's behalf without a yes.
