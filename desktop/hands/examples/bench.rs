fn main() {
    let body = cookie_hands::body().unwrap();
    for name in std::env::args().skip(1) {
        let mut times = vec![];
        let mut n = 0; let mut trunc = false;
        for _ in 0..5 {
            let s = body.look(&cookie_hands::Look { app: Some(name.clone()), pid: None, limit: 600 }).unwrap();
            times.push(s.took_ms); n = s.nodes.len(); trunc = s.truncated;
        }
        times.sort();
        println!("{name}: {n} items{} · look median {} ms, best {} ms", if trunc {" (capped)"} else {""}, times[2], times[0]);
    }
}
