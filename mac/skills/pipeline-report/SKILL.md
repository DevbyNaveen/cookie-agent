---
name: pipeline-report
description: Pipeline report from CRM rows: deals by stage, movement this period, stuck deals with days stuck, and any chance-to-close shown with the rows and method behind it.
---
# Pipeline report

Use for "how's the pipeline", weekly sales review, forecast prep.

## Ask only if missing
- Period. Default: last 7 days (weekly) and the current quarter for totals.
- Owner filter (whole team or one rep). Default: whole team.

## Procedure
1. `connector_actions`, then `connector_call` to pull every open deal and every deal closed in the period: id, name, stage, amount, currency, owner, created date, stage-entered date (or last stage change), close date, last activity date. Page through until all rows are fetched; record the count.
2. If the CRM can't return stage-change history, say so; "movement" then compares against the last report in `recall`, or is marked "not available".
3. Compute only from those rows:
   - By stage: count, sum of amount, per currency (never convert currencies without a rate the person gives).
   - Movement in period: new deals, stage advances, stage regressions, won, lost (with loss reason if the field exists).
   - Stuck: days in current stage = today − stage-entered date. Flag deals over the threshold (default 21 days, or 2× the stage's median from these rows).
   - Missing hygiene: no next step, close date in the past, no activity in 14+ days.
4. Chance to close: only if the person asks. Allowed methods, stated with the result:
   - The CRM's own stage probability field (say it's the CRM's setting), or
   - Historical stage conversion from closed deals in these rows: won ÷ (won + lost) among deals that reached that stage, with n. If n < 10, say the sample is too small.
   Show the rows it was computed from. Never a made-up percentage.
5. Build the spreadsheet with `make_spreadsheet` (sheets: Summary, Deals, Stuck) if they want a file; keep raw rows in Deals.
6. Offer `remember` for the period totals so next week can show movement.

## Output format
```text
# Pipeline — <period> (from <CRM>, <n> deals, pulled <timestamp>)

## By stage
| Stage | Deals | Amount |
|---|---|---|

## This period
New: <n> (<sum>) · Advanced: <n> · Slipped back: <n> · Won: <n> (<sum>) · Lost: <n> (<sum>)

## Stuck (over <threshold> days in stage)
| Deal | Stage | Days stuck | Owner | Last activity |
|---|---|---|---|---|

## Hygiene
- <n> deals with close date in the past: <names>
- <n> deals with no next step: <names>

## Chance to close (if asked)
Method: <method>, n = <rows>. <result per stage>
```

## Quality bar
- Every number can be recomputed from the Deals sheet.
- Sorted by what needs action: stuck and past-due first.
- Totals match the sum of rows; check before showing.

## Never
- Estimate, round up or fill a missing amount or date. Missing is shown as missing.
- Present a probability without its method and rows.
- Change CRM records from this skill (that's crm-update, with a yes).
