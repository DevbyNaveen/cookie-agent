# Cookie skills

Playbooks Cookie's agent loads on demand through its core.

## How they load
- `Skills::from_dir("skills")` reads every `skills/*/SKILL.md`; a folder without one is skipped, and two skills with the same `name` is an error.
- The model sees one tool, `use_skill`, whose description lists `- name: description` for every skill. Calling it with a name returns that skill's body (everything after the frontmatter). Nothing is added to Cookie's instructions.
- Only `SKILL.md` is served. There is no reference-file loading, so each skill is self-contained.
- Format: the file starts with `---`, then top-level `key: value` lines (`name` and `description` required, non-empty; quotes stripped; `>` folds and `|` keeps a block), then `---`, then the Markdown body.
- Not wired yet: `cookie serve` (what Cookie's helper runs) does not pass skills to the agent today; whoever adds that calls `Skills::from_dir(<bundle>/skills)?.into_tools()`.

## The skills
| Skill | For |
|---|---|
| research-report | Sourced answer to a research question |
| company-brief | One page on a company |
| person-brief | Professional brief on a business contact (public professional info + own apps only) |
| meeting-brief | Prep: company, people, deal, last interactions, promises, 3 questions |
| meeting-notes | Decisions, action items, open questions from a transcript |
| outreach-draft | First touch: observation, relevance, one ask; saved as a draft |
| follow-up-draft | References the last exchange and the promised item; saved as a draft |
| crm-update | Field-by-field CRM changes, written on a yes |
| pipeline-report | By stage, movement, stuck deals, from CRM rows |
| prospect-list | Companies that fit, each with a sourced reason why now |
| competitor-analysis | Sourced comparison, where we win and lose |
| gtm-plan | One segment, one channel, 30/60/90 days, real numbers |
| linkedin-post | Post in the person's voice from a real story |
| landing-page | Copy + page file, one call to action |
| proposal | Client proposal from discovery notes and real pricing |
| spreadsheet | Build, read or change sheets, files or live apps |
| document | Memos, reports, letters |
| deck | Slides with takeaway titles and sourced numbers |
| web-page | Single shareable page |
| teach-me | Point, explain, wait; the person does each step |
| do-it-on-my-mac | One-approval plan, then Cookie does the steps |

## Check
`python3 skills/validate.py` — mirrors the harness's frontmatter parsing, requires `name` == folder, keeps descriptions one line ≤ 250 chars and bodies ≤ 120 lines / 12 KB (Cookie's budgets; the harness sets none), allows only the tools Cookie offers, flags banned customer words inside output templates, and fails on extra files the harness would never serve.
