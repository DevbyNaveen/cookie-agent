//! Look at apps without touching anything: `cargo run --example probe -- Finder "Google Chrome"`.
fn main() {
    let body = cookie_hands::body().expect("no hands on this system");
    if let Err(e) = body.ready() { eprintln!("{e}"); return; }
    let apps = body.apps().unwrap();
    println!("{} apps open: {}", apps.len(), apps.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", "));
    for name in std::env::args().skip(1) {
        for round in 0..2 {
            match body.look(&cookie_hands::Look { app: Some(name.clone()), pid: None, limit: 60 }) {
                Ok(s) => {
                    if round == 1 { println!("{}", cookie_hands::render(&s).lines().take(18).collect::<Vec<_>>().join("\n")); }
                    else { println!("--- {name}: first look {} ms, {} items", s.took_ms, s.nodes.len()); }
                }
                Err(e) => { println!("--- {name}: {e}"); break; }
            }
        }
        let t = std::time::Instant::now();
        let pid = body.apps().unwrap().into_iter().find(|a| a.name == name).map(|a| a.pid).unwrap_or(0);
        let changed = body.wait_change(pid, std::time::Duration::from_millis(300));
        println!("wait_change(300ms) -> {changed} after {} ms\n", t.elapsed().as_millis());
    }
}
