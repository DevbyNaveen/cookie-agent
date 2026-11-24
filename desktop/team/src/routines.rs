//! Routines: standing jobs on a schedule, in this computer's local time.
//! The scheduler wakes every 20 seconds and starts what is due; a busy agent
//! gets its routine as soon as it is free (never two at once, never skipped
//! silently: a routine missed while the computer slept runs once on wake).

use std::sync::Arc;
use std::time::Duration;

use chrono::{Datelike, Local, NaiveTime, TimeZone, Timelike, Weekday};

use crate::events::TeamEvent;
use crate::store::{Routine, Schedule, Trigger};
use crate::{util, Team};

const DAYS: [(&str, Weekday); 7] = [
    ("mon", Weekday::Mon), ("tue", Weekday::Tue), ("wed", Weekday::Wed), ("thu", Weekday::Thu),
    ("fri", Weekday::Fri), ("sat", Weekday::Sat), ("sun", Weekday::Sun),
];

fn time_of(at: &str) -> Result<NaiveTime, String> {
    NaiveTime::parse_from_str(at.trim(), "%H:%M").map_err(|_| format!("`{at}` isn't a time; use HH:MM, like 08:30."))
}

fn weekday_of(day: &str) -> Result<Weekday, String> {
    let d = day.trim().to_lowercase();
    DAYS.iter().find(|(n, _)| d.starts_with(n)).map(|(_, w)| *w).ok_or_else(|| format!("`{day}` isn't a day of the week."))
}

pub fn validate(s: &Schedule) -> Result<(), String> {
    match s {
        Schedule::Day { at } | Schedule::Weekday { at } => time_of(at).map(|_| ()),
        Schedule::Week { day, at } => weekday_of(day).and(time_of(at)).map(|_| ()),
        Schedule::Minutes { n } if *n >= 15 && *n <= 7 * 24 * 60 => Ok(()),
        Schedule::Minutes { .. } => Err("Every 15 minutes at most often, and once a week at least.".into()),
    }
}

pub fn describe(s: &Schedule) -> String {
    match s {
        Schedule::Day { at } => format!("every day at {at}"),
        Schedule::Weekday { at } => format!("weekdays at {at}"),
        Schedule::Week { day, at } => format!("every {} at {at}", weekday_of(day).map(|w| format!("{w:?}")).unwrap_or_else(|_| day.clone())),
        Schedule::Minutes { n } if n % 60 == 0 => format!("every {} hour{}", n / 60, if *n == 60 { "" } else { "s" }),
        Schedule::Minutes { n } => format!("every {n} minutes"),
    }
}

pub fn local_time(t: u64) -> String {
    Local.timestamp_opt(t as i64, 0).single().map(|d| d.format("%a %-d %b, %H:%M").to_string()).unwrap_or_default()
}

/// The first run strictly after `after` (seconds since the epoch).
pub fn next_after(s: &Schedule, after: u64) -> Option<u64> {
    let from = Local.timestamp_opt(after as i64, 0).single()?;
    if let Schedule::Minutes { n } = s {
        return Some(after + *n as u64 * 60);
    }
    let (time, ok_day): (NaiveTime, Box<dyn Fn(Weekday) -> bool>) = match s {
        Schedule::Day { at } => (time_of(at).ok()?, Box::new(|_| true)),
        Schedule::Weekday { at } => (time_of(at).ok()?, Box::new(|w| !matches!(w, Weekday::Sat | Weekday::Sun))),
        Schedule::Week { day, at } => {
            let want = weekday_of(day).ok()?;
            (time_of(at).ok()?, Box::new(move |w| w == want))
        }
        Schedule::Minutes { .. } => unreachable!(),
    };
    for add in 0..=8 {
        let date = from.date_naive() + chrono::Duration::days(add);
        if !ok_day(date.weekday()) {
            continue;
        }
        // A local time that doesn't exist (a DST jump) moves an hour later.
        let dt = Local.from_local_datetime(&date.and_time(time)).earliest().or_else(|| Local.from_local_datetime(&date.and_hms_opt(time.hour() + 1, time.minute(), 0)?).earliest())?;
        if dt > from {
            return Some(dt.timestamp() as u64);
        }
    }
    None
}

impl Team {
    pub async fn routines(&self) -> Vec<Routine> {
        self.routines.read().await.clone()
    }

    pub async fn routines_of(&self, agent: &str) -> Vec<Routine> {
        self.routines.read().await.iter().filter(|r| r.agent == agent).cloned().collect()
    }

    pub(crate) async fn save_routines(&self, rs: &[Routine]) -> Result<(), String> {
        util::write_json(&self.paths.routines(), rs)?;
        self.emit(TeamEvent::RoutinesChanged);
        Ok(())
    }

    pub async fn add_routine(&self, agent: &str, task: &str, schedule: Schedule) -> Result<Routine, String> {
        validate(&schedule)?;
        self.agent(agent).await?;
        let now = util::now();
        let r = Routine {
            id: util::new_id("routine"),
            agent: agent.to_string(),
            task: task.trim().to_string(),
            next_run: next_after(&schedule, now),
            schedule,
            enabled: true,
            created_at: now,
            last_run: None,
        };
        let mut rs = self.routines.write().await;
        rs.push(r.clone());
        self.save_routines(&rs).await?;
        Ok(r)
    }

    pub async fn update_routine(&self, id: &str, task: Option<String>, schedule: Option<Schedule>) -> Result<Routine, String> {
        let mut rs = self.routines.write().await;
        let r = rs.iter_mut().find(|r| r.id == id).ok_or("No such routine.")?;
        if let Some(t) = task.filter(|t| !t.trim().is_empty()) {
            r.task = t.trim().to_string();
        }
        if let Some(s) = schedule {
            validate(&s)?;
            r.next_run = next_after(&s, util::now());
            r.schedule = s;
        }
        let out = r.clone();
        self.save_routines(&rs).await?;
        Ok(out)
    }

    pub async fn set_routine_enabled(&self, id: &str, enabled: bool) -> Result<(), String> {
        let mut rs = self.routines.write().await;
        let r = rs.iter_mut().find(|r| r.id == id).ok_or("No such routine.")?;
        r.enabled = enabled;
        if enabled {
            r.next_run = next_after(&r.schedule, util::now());
        }
        self.save_routines(&rs).await
    }

    pub async fn delete_routine(&self, id: &str) -> Result<(), String> {
        let mut rs = self.routines.write().await;
        rs.retain(|r| r.id != id);
        self.save_routines(&rs).await
    }

    /// Run a routine now, outside its schedule.
    pub async fn run_routine_now(self: &Arc<Self>, id: &str) -> Result<String, String> {
        let r = self.routines.read().await.iter().find(|r| r.id == id).cloned().ok_or("No such routine.")?;
        self.start_job(&r.agent, r.task.clone(), Vec::new(), Trigger::Routine { routine: r.id.clone() }).await
    }

    async fn tick(self: &Arc<Self>) {
        self.curate().await;
        self.maybe_post_retro().await;
        // The nightly exam loop, when it is on and its hour has come.
        self.maybe_evolve().await;
        // Idle agents get ready for routines due soon; local models stay loaded while used.
        self.maybe_prepare().await;
        self.keep_local_models_warm().await;
        let now = util::now();
        let due: Vec<Routine> = self.routines.read().await.iter().filter(|r| r.enabled && r.next_run.is_some_and(|t| t <= now)).cloned().collect();
        // One snapshot a day of each agent that worked today (`sleep`).
        let ids: Vec<String> = self.agents().await.into_iter().filter(|a| a.shadow_of.is_none()).map(|a| a.id).collect();
        self.daily_snapshots(&ids);
        for r in due {
            // An agent that may also run in the cloud waits for the first sync,
            // so a turn the cloud took while the Mac was off isn't run twice.
            if !crate::cloud::first_sync_done() && self.settings().await.cloud.run_when_off.contains(&r.agent) {
                continue;
            }
            // An asleep agent's routine skips its turn quietly: the schedule moves on.
            if self.is_asleep(&r.agent) {
                let mut rs = self.routines.write().await;
                if let Some(x) = rs.iter_mut().find(|x| x.id == r.id) {
                    x.next_run = next_after(&x.schedule, now);
                }
                let _ = self.save_routines(&rs).await;
                continue;
            }
            let started = self.start_job(&r.agent, r.task.clone(), Vec::new(), Trigger::Routine { routine: r.id.clone() }).await;
            if started.is_err() && self.runs.lock().unwrap().contains_key(&r.agent) {
                continue; // busy: try again on the next tick
            }
            let mut rs = self.routines.write().await;
            if let Some(x) = rs.iter_mut().find(|x| x.id == r.id) {
                x.last_run = Some(now);
                // A run missed while asleep happens once, then the schedule resumes.
                x.next_run = next_after(&x.schedule, now);
            }
            let _ = self.save_routines(&rs).await;
            if let Err(e) = started {
                if let Ok(a) = self.agent(&r.agent).await {
                    self.notice(&a.id, &format!("{}'s routine didn't start", a.name), &e, None, false);
                }
            }
        }
    }
}

/* ---------- a job given again and again, offered once as a routine ---------- */
//
// Whether a job is one the person gives on a cadence (alike enough, regular
// enough, never offered before) is the harness's (`lessons::routine`). The
// offer is made once; declined, a job like it is never offered again.
// Ported from the super console (gateway `cookie/routine.rs`).

/// How far back the person's own jobs are read for a cadence.
const OFFER_LOOKBACK_DAYS: u64 = 35;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct RoutineOffer {
    pub id: String,
    pub agent: String,
    pub task: String,
    pub schedule: Schedule,
    /// Jobs alike it was seen in.
    pub seen: usize,
    /// `open`, `accepted` or `declined`.
    pub state: String,
    pub at: u64,
}

const WEEKDAYS: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

impl Team {
    fn offers_path(&self) -> std::path::PathBuf {
        self.paths.root.join("routine-offers.json")
    }

    pub fn routine_offers(&self) -> Vec<RoutineOffer> {
        util::read_json(&self.offers_path())
    }

    /// After a job the person gave: is it one they give on a cadence?
    pub(crate) async fn maybe_offer_routine(&self, agent: &str, job: &crate::store::Job) -> Option<RoutineOffer> {
        if !matches!(job.trigger, Trigger::Chat | Trigger::Telegram { .. } | Trigger::Channel { .. }) || job.status != crate::store::JobStatus::Done {
            return None;
        }
        let since = util::now().saturating_sub(OFFER_LOOKBACK_DAYS * 86_400);
        let past: Vec<(String, f64)> = util::read_jsonl::<crate::store::Job>(&self.paths.jobs(agent))
            .into_iter()
            .filter(|j| j.started_at >= since && matches!(j.trigger, Trigger::Chat | Trigger::Telegram { .. } | Trigger::Channel { .. }))
            .map(|j| (j.input, j.started_at as f64))
            .collect();
        let mut offers = self.routine_offers();
        let mut known: Vec<String> = offers.iter().filter(|o| o.agent == agent).map(|o| o.task.clone()).collect();
        known.extend(self.routines_of(agent).await.into_iter().map(|r| r.task));
        let tz = Local::now().offset().local_minus_utc() as i64 / 60;
        let found = cookie_harness::lessons::routine(&job.input, &past, tz, &known)?;
        let at = format!("{:02}:{:02}", found.hour, found.minute);
        let schedule = if found.cadence == "weekly" {
            Schedule::Week { day: WEEKDAYS[(found.weekday.clamp(1, 7) - 1) as usize].into(), at }
        } else {
            Schedule::Day { at }
        };
        let offer = RoutineOffer { id: util::new_id("offer"), agent: agent.to_string(), task: job.input.clone(), schedule, seen: found.seen, state: "open".into(), at: util::now() };
        offers.push(offer.clone());
        util::write_json(&self.offers_path(), &offers).ok()?;
        if let Ok(a) = self.agent(agent).await {
            self.notice(agent, &format!("Make it a routine for {}?", a.name), &format!("You've asked this {} times, {}: \"{}\"", found.seen, describe(&offer.schedule), util::clip(&offer.task, 140)), Some(&job.id), false);
        }
        self.emit(TeamEvent::RoutinesChanged);
        Some(offer)
    }

    /// The person answers an offer: yes makes the routine, no is never asked again.
    pub async fn answer_routine_offer(&self, id: &str, yes: bool) -> Result<Option<Routine>, String> {
        let mut offers = self.routine_offers();
        let o = offers.iter_mut().find(|o| o.id == id).ok_or("No such offer.")?;
        if o.state != "open" {
            return Err("That offer was already answered.".into());
        }
        o.state = if yes { "accepted" } else { "declined" }.into();
        let made = if yes { Some(self.add_routine(&o.agent, &o.task, o.schedule.clone()).await?) } else { None };
        util::write_json(&self.offers_path(), &offers)?;
        self.emit(TeamEvent::RoutinesChanged);
        Ok(made)
    }
}

pub(crate) fn spawn_scheduler(team: Arc<Team>) {
    tokio::spawn(async move {
        let mut every = tokio::time::interval(Duration::from_secs(20));
        loop {
            every.tick().await;
            team.tick().await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_runs_are_in_the_future_and_respect_days() {
        let now = util::now();
        for s in [
            Schedule::Day { at: "08:30".into() },
            Schedule::Weekday { at: "09:00".into() },
            Schedule::Week { day: "fri".into(), at: "17:00".into() },
            Schedule::Minutes { n: 90 },
        ] {
            let t = next_after(&s, now).unwrap();
            assert!(t > now && t <= now + 8 * 86_400, "{s:?}");
        }
        let fri = next_after(&Schedule::Week { day: "fri".into(), at: "17:00".into() }, now).unwrap();
        assert_eq!(Local.timestamp_opt(fri as i64, 0).unwrap().weekday(), Weekday::Fri);
        let wd = next_after(&Schedule::Weekday { at: "09:00".into() }, now).unwrap();
        assert!(!matches!(Local.timestamp_opt(wd as i64, 0).unwrap().weekday(), Weekday::Sat | Weekday::Sun));
    }

    #[test]
    fn bad_schedules_are_refused() {
        assert!(validate(&Schedule::Day { at: "25:00".into() }).is_err());
        assert!(validate(&Schedule::Week { day: "someday".into(), at: "08:00".into() }).is_err());
        assert!(validate(&Schedule::Minutes { n: 5 }).is_err());
        assert_eq!(describe(&Schedule::Minutes { n: 120 }), "every 2 hours");
    }
}
