fn main() {
    let body = cookie_hands::body().unwrap();
    let name = std::env::args().nth(1).unwrap();
    let pid = body.apps().unwrap().into_iter().find(|a| a.name == name).unwrap().pid;
    let t = std::time::Instant::now();
    match body.screenshot(pid) {
        Ok(s) => { std::fs::write(std::env::args().nth(2).unwrap(), &s.png).unwrap(); println!("{}x{} png, {} KB, {} ms", s.width, s.height, s.png.len() / 1024, t.elapsed().as_millis()); }
        Err(e) => println!("{e}"),
    }
}
