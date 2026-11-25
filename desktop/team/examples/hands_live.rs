//! A real agent using Cookie Hands, read only, in a throwaway team folder.
use cookie_team::store::{Grants, Trigger};
use cookie_team::{Hire, Team};

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-hands-live-{}", std::process::id()));
    let team = Team::open(&dir).unwrap();
    let rec = team
        .hire(Hire {
            name: "Mac Hand".into(),
            job: "Read and use apps on this Mac when asked.".into(),
            model: "anthropic:claude-sonnet-4-6".into(),
            grants: Some(Grants { mac: true, ..Grants::default() }),
            probation_days: 0,
            ..Hire::default()
        })
        .await
        .unwrap();
    let ask = std::env::args().nth(1).unwrap();
    let started = std::time::Instant::now();
    let job = team.run_and_wait(&rec.id, ask, vec![], Trigger::Chat).await.unwrap();
    println!("status: {:?} in {:.1} s", job.status, started.elapsed().as_secs_f64());
    println!("tools: {:?}", job.tools);
    println!("error: {:?}", job.error);
    println!("answer:\n{}", job.answer);
    let _ = std::fs::remove_dir_all(&dir);
}
