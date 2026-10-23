---
name: linkedin-post
description: Write a LinkedIn post in the person's own voice from a real story, result or opinion they have; shows options, posts only on their yes.
---
# LinkedIn post

Use for "write a LinkedIn post about X", announcing a launch, sharing a lesson.

## Ask only if missing
- The point: one thing the reader should take away.
- The raw material: the story, number or event (or where to find it: `recall`, a document, a page).

## Procedure
1. `recall` the person's past posts, tone, and the facts behind this post. If they have none, ask for one past post they liked.
2. Check every fact in the post: numbers from their records or a sourced page; customer names only if `recall` or the CRM shows the customer agreed to be named. `check_quote` any quote from a third party.
3. Write 2 versions with different hooks:
   - Hook (first 2 lines, shown before "see more"): a concrete moment, number or claim. No "I'm excited to announce".
   - Body: short lines, one idea, a specific detail only the author could know.
   - End: a question or a clear next step. Max 3 hashtags, or none.
   - 120–220 words unless they want long-form.
4. Disclosure: suggest an optional line ("Drafted with help from an AI assistant."); explain it's their call where the EU AI Act (Art. 50) doesn't require it.
5. Show both versions side by side with the facts list and sources.
6. Posting: only if they say "post it". Then `connector_actions` to find the LinkedIn post action and `connector_call`; Cookie's card asks for the final yes. Otherwise leave it as text to copy.

## Output format
```text
Version A — <hook style>
<post>

Version B — <hook style>
<post>

Facts used:
- <fact> — <source>
```

## Quality bar
- Sounds like the person, not like LinkedIn. Read it aloud; cut every sentence that could be in anyone's post.
- One idea per post.
- No engagement bait ("Agree?"), no fake vulnerability, no em-dash-stuffed listicles.

## Never
- Invent a story, number, customer, quote or result.
- Name a person or customer who hasn't agreed to be named.
- Post, schedule or edit a live post without the yes on Cookie's card.
