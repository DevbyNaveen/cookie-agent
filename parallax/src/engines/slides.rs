//! Slides: a deck written as structured slides, made into a real, editable
//! PowerPoint file (`.pptx`, opens in Keynote, PowerPoint and Google Slides),
//! a PDF, or a self-contained HTML deck that plays in any browser.
//!
//! The deck is data, not drawing: a title, a theme, and slides each with a
//! layout (title, section, bullets, two columns, image, quote, closing), so an
//! agent writes what to say and the engine lays it out the same way every
//! time. Images are files in the world.
//!
//! `.pptx` is written with `python-pptx` (MIT), pinned, in a private Python
//! environment Parallax makes once beside its worlds. PDF comes from
//! LibreOffice when it is installed (the `.pptx` converted, so both match),
//! else from Chrome printing the HTML deck. Each says plainly when its tool
//! is missing.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

/// The python-pptx release every world uses.
pub const PYTHON_PPTX: &str = "python-pptx==1.0.2";
pub const LAYOUTS: [&str; 7] = ["title", "section", "bullets", "two_columns", "image", "quote", "closing"];
pub const THEMES: [&str; 3] = ["dark", "light", "warm"];
const MAX_SLIDES: usize = 80;

pub struct Slides;

/// A deck checked before anything is made: layouts known, text present, images in the world.
pub fn check_deck(ctx: &Ctx, deck: &Value) -> Result<Value, String> {
    let slides = deck["slides"].as_array().ok_or("A deck has `slides`: a list of slides.")?;
    if slides.is_empty() || slides.len() > MAX_SLIDES {
        return Err(format!("A deck has 1 to {MAX_SLIDES} slides."));
    }
    let theme = deck["theme"].as_str().unwrap_or("dark");
    if !THEMES.contains(&theme) {
        return Err(format!("The theme is one of {}.", THEMES.join(", ")));
    }
    let mut out = Vec::new();
    for (i, sl) in slides.iter().enumerate() {
        let layout = sl["layout"].as_str().unwrap_or("bullets");
        if !LAYOUTS.contains(&layout) {
            return Err(format!("Slide {}: the layout is one of {}.", i + 1, LAYOUTS.join(", ")));
        }
        let mut sl = sl.clone();
        sl["layout"] = json!(layout);
        if let Some(img) = sl["image"].as_str().filter(|p| !p.is_empty()) {
            let p = ctx.path(img)?;
            if !p.is_file() {
                return Err(format!("Slide {}: there is no image at {img}.", i + 1));
            }
            sl["image"] = json!(p.to_string_lossy());
        } else if layout == "image" {
            return Err(format!("Slide {}: an image slide needs `image`, a file in the world.", i + 1));
        }
        out.push(sl);
    }
    Ok(json!({"title": deck["title"].as_str().unwrap_or(""), "theme": theme, "slides": out}))
}

/// The private Python with python-pptx, made on first use.
async fn python(home: &Path) -> Result<PathBuf, String> {
    let env = home.join("python");
    let py = env.join("bin/python3");
    let ready = env.join(".pptx-ready");
    if py.is_file() && ready.is_file() && std::fs::read_to_string(&ready).unwrap_or_default().trim() == PYTHON_PPTX {
        return Ok(py);
    }
    let system = super::tool(&["python3"]).ok_or("Slides need Python 3 (it comes with Apple's command line tools).")?;
    std::fs::create_dir_all(home).map_err(|e| e.to_string())?;
    super::run(&system, &["-m", "venv", &env.to_string_lossy()], home).await?;
    super::run(&py.to_string_lossy(), &["-m", "pip", "install", "--quiet", "--disable-pip-version-check", PYTHON_PPTX], home).await.map_err(|e| format!("Couldn't install {PYTHON_PPTX}: {e}"))?;
    std::fs::write(&ready, PYTHON_PPTX).map_err(|e| e.to_string())?;
    Ok(py)
}

/// The script that lays a deck out. Reads the deck as JSON from a file, writes the .pptx.
const PPTX_SCRIPT: &str = r#"
import json, sys
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

deck = json.load(open(sys.argv[1]))
out = sys.argv[2]
THEMES = {
    "dark":  {"bg": "141414", "fg": "F5F2EC", "muted": "A39E95", "accent": "E07A3F"},
    "light": {"bg": "FBFAF7", "fg": "1C1B19", "muted": "6B665E", "accent": "C2552B"},
    "warm":  {"bg": "F4EBDD", "fg": "2A211A", "muted": "7A6A5A", "accent": "B4532A"},
}
t = THEMES.get(deck.get("theme", "dark"), THEMES["dark"])
rgb = lambda h: RGBColor.from_string(h)
prs = Presentation()
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
W, H = prs.slide_width, prs.slide_height
blank = prs.slide_layouts[6]

def paint(slide):
    bg = slide.background.fill
    bg.solid()
    bg.fore_color.rgb = rgb(t["bg"])

def text(slide, x, y, w, h, value, size, color, bold=False, align=PP_ALIGN.LEFT):
    box = slide.shapes.add_textbox(x, y, w, h)
    tf = box.text_frame
    tf.word_wrap = True
    lines = value if isinstance(value, list) else [value]
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        r = p.add_run()
        r.text = str(line)
        r.font.size = Pt(size)
        r.font.bold = bold
        r.font.color.rgb = rgb(color)
        p.space_after = Pt(size * 0.6)
    return box

def bullets(slide, x, y, w, h, items, size=24):
    box = slide.shapes.add_textbox(x, y, w, h)
    tf = box.text_frame
    tf.word_wrap = True
    for i, item in enumerate(items):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        r = p.add_run()
        r.text = "•  " + str(item)
        r.font.size = Pt(size)
        r.font.color.rgb = rgb(t["fg"])
        p.space_after = Pt(14)

def picture(slide, path, x, y, w, h):
    pic = slide.shapes.add_picture(path, x, y)
    scale = min(w / pic.width, h / pic.height)
    pic.width, pic.height = int(pic.width * scale), int(pic.height * scale)
    pic.left, pic.top = int(x + (w - pic.width) / 2), int(y + (h - pic.height) / 2)

M = Inches(0.8)
for s in deck["slides"]:
    slide = prs.slides.add_slide(blank)
    paint(slide)
    lay = s.get("layout", "bullets")
    title = s.get("title", "")
    if lay in ("title", "closing"):
        text(slide, M, Inches(2.4), W - 2 * M, Inches(1.6), title, 54, t["fg"], bold=True)
        if s.get("text"):
            text(slide, M, Inches(4.1), W - 2 * M, Inches(1.2), s["text"], 24, t["muted"])
    elif lay == "section":
        text(slide, M, Inches(1.2), Inches(2), Inches(0.6), s.get("kicker", ""), 16, t["accent"], bold=True)
        text(slide, M, Inches(2.8), W - 2 * M, Inches(1.6), title, 46, t["fg"], bold=True)
    elif lay == "quote":
        text(slide, Inches(1.4), Inches(1.8), W - Inches(2.8), Inches(3), "“" + s.get("text", "") + "”", 36, t["fg"])
        if title:
            text(slide, Inches(1.4), Inches(5.2), W - Inches(2.8), Inches(0.8), "— " + title, 20, t["muted"])
    elif lay == "image":
        if title:
            text(slide, M, Inches(0.5), W - 2 * M, Inches(0.9), title, 32, t["fg"], bold=True)
        picture(slide, s["image"], M, Inches(1.5), W - 2 * M, H - Inches(2.2))
    elif lay == "two_columns":
        text(slide, M, Inches(0.6), W - 2 * M, Inches(1), title, 36, t["fg"], bold=True)
        half = (W - 2 * M - Inches(0.6)) / 2
        bullets(slide, M, Inches(1.9), half, H - Inches(2.6), s.get("left", []), 22)
        bullets(slide, M + half + Inches(0.6), Inches(1.9), half, H - Inches(2.6), s.get("right", []), 22)
    else:
        text(slide, M, Inches(0.6), W - 2 * M, Inches(1), title, 36, t["fg"], bold=True)
        w = W - 2 * M
        if s.get("image"):
            w = (W - 2 * M) * 0.55
            picture(slide, s["image"], M + w + Inches(0.4), Inches(1.9), W - 2 * M - w - Inches(0.4), H - Inches(2.6))
        bullets(slide, M, Inches(1.9), w, H - Inches(2.6), s.get("bullets", []))
    if s.get("notes"):
        slide.notes_slide.notes_text_frame.text = s["notes"]
prs.save(out)
print(len(deck["slides"]))
"#;

fn esc(t: &str) -> String {
    t.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// A self-contained HTML deck: arrow keys and clicks move, `p` prints a slide per page.
pub fn html_deck(deck: &Value) -> String {
    let theme = deck["theme"].as_str().unwrap_or("dark");
    let (bg, fg, muted, accent) = match theme {
        "light" => ("#FBFAF7", "#1C1B19", "#6B665E", "#C2552B"),
        "warm" => ("#F4EBDD", "#2A211A", "#7A6A5A", "#B4532A"),
        _ => ("#141414", "#F5F2EC", "#A39E95", "#E07A3F"),
    };
    let list = |v: &Value| v.as_array().into_iter().flatten().filter_map(|x| x.as_str()).map(|x| format!("<li>{}</li>", esc(x))).collect::<String>();
    let img = |s: &Value| s["image"].as_str().map(|p| format!("<img src=\"file://{}\" alt=\"\">", esc(p))).unwrap_or_default();
    let mut slides = String::new();
    for sl in deck["slides"].as_array().into_iter().flatten() {
        let title = esc(sl["title"].as_str().unwrap_or(""));
        let text = esc(sl["text"].as_str().unwrap_or(""));
        let body = match sl["layout"].as_str().unwrap_or("bullets") {
            "title" | "closing" => format!("<h1>{title}</h1><p class=sub>{text}</p>"),
            "section" => format!("<p class=kicker>{}</p><h1>{title}</h1>", esc(sl["kicker"].as_str().unwrap_or(""))),
            "quote" => format!("<blockquote>“{text}”</blockquote><p class=sub>{}</p>", if title.is_empty() { String::new() } else { format!("— {title}") }),
            "image" => format!("<h2>{title}</h2><div class=full>{}</div>", img(sl)),
            "two_columns" => format!("<h2>{title}</h2><div class=cols><ul>{}</ul><ul>{}</ul></div>", list(&sl["left"]), list(&sl["right"])),
            _ => format!("<h2>{title}</h2><div class=cols><ul>{}</ul>{}</div>", list(&sl["bullets"]), img(sl)),
        };
        slides.push_str(&format!("<section class=\"slide {}\">{body}</section>\n", sl["layout"].as_str().unwrap_or("bullets")));
    }
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>
<style>
:root{{--bg:{bg};--fg:{fg};--muted:{muted};--accent:{accent}}}
*{{box-sizing:border-box;margin:0}}html,body{{height:100%;background:var(--bg);color:var(--fg);font:400 24px/1.4 -apple-system,"Helvetica Neue",Arial,sans-serif}}
.slide{{position:absolute;inset:0;padding:7vh 7vw;display:none;flex-direction:column;justify-content:center;gap:3vh}}.slide.on{{display:flex}}
h1{{font-size:clamp(36px,6vw,80px);line-height:1.05;letter-spacing:-.02em}}h2{{font-size:clamp(28px,3.6vw,52px);letter-spacing:-.015em}}
.sub{{color:var(--muted);font-size:clamp(18px,2vw,30px)}}.kicker{{color:var(--accent);font-weight:700;text-transform:uppercase;letter-spacing:.08em;font-size:16px}}
blockquote{{font-size:clamp(26px,3.4vw,48px);line-height:1.25;max-width:22ch}}ul{{padding-left:1.1em;display:grid;gap:1.6vh;font-size:clamp(18px,2vw,30px)}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:4vw;align-items:center}}img{{max-width:100%;max-height:60vh;border-radius:12px;object-fit:contain}}.full img{{max-height:72vh}}
.n{{position:fixed;right:2vw;bottom:2vh;color:var(--muted);font-size:14px}}
@media print{{.slide{{display:flex!important;position:relative;height:100vh;page-break-after:always}}.n{{display:none}}}}
</style></head><body>
{slides}<div class=n></div>
<script>
const s=[...document.querySelectorAll('.slide')];let i=0;const n=document.querySelector('.n');
const go=k=>{{i=Math.max(0,Math.min(s.length-1,k));s.forEach((x,j)=>x.classList.toggle('on',j===i));n.textContent=(i+1)+' / '+s.length;}};
addEventListener('keydown',e=>{{if(['ArrowRight','PageDown',' '].includes(e.key))go(i+1);if(['ArrowLeft','PageUp'].includes(e.key))go(i-1);if(e.key==='p')print();}});
addEventListener('click',e=>go(e.clientX>innerWidth/2?i+1:i-1));go(0);
</script></body></html>"#,
        title = esc(deck["title"].as_str().unwrap_or("Slides"))
    )
}

#[async_trait]
impl Engine for Slides {
    fn name(&self) -> &'static str {
        "slides"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let deck = json!({"type": "object", "description": "{title, theme (dark|light|warm), slides: [{layout (title|section|bullets|two_columns|image|quote|closing), title, text, kicker, bullets: [], left: [], right: [], image (a file in the world), notes}]}"});
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new("slides", "make", "Make the deck as a PowerPoint file at `to` (.pptx): editable in Keynote, PowerPoint and Google Slides.", json!({"type": "object", "properties": {"deck": deck, "to": p}, "required": ["deck", "to"]}), Effect::Local),
            ActionSpec::new("slides", "html", "Make the deck as one HTML file at `to` that plays in any browser (arrow keys; p prints).", json!({"type": "object", "properties": {"deck": deck, "to": p}, "required": ["deck", "to"]}), Effect::Local),
            ActionSpec::new("slides", "pdf", "Make a PDF at `to`: from a .pptx `path` (LibreOffice), or from `deck` (printed by Chrome).", json!({"type": "object", "properties": {"path": p, "deck": deck, "to": p}, "required": ["to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let to_rel = s(args, "to")?;
        let to = ctx.path(to_rel)?;
        if let Some(p) = to.parent() {
            std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
        }
        match action {
            "make" => {
                if to.extension().is_none_or(|e| e != "pptx") {
                    return Err("A PowerPoint file ends in .pptx.".into());
                }
                let deck = check_deck(ctx, &args["deck"])?;
                let py = python(&ctx.home).await?;
                let work = ctx.state.join("slides");
                std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
                let (deck_file, script) = (work.join("deck.json"), work.join("make_pptx.py"));
                std::fs::write(&deck_file, deck.to_string()).map_err(|e| e.to_string())?;
                std::fs::write(&script, PPTX_SCRIPT).map_err(|e| e.to_string())?;
                let n = super::run(&py.to_string_lossy(), &[&script.to_string_lossy(), &deck_file.to_string_lossy(), &to.to_string_lossy()], &ctx.files).await?;
                Ok(json!({"written": to_rel, "slides": n.trim().parse::<usize>().unwrap_or(0)}))
            }
            "html" => {
                let deck = check_deck(ctx, &args["deck"])?;
                std::fs::write(&to, html_deck(&deck)).map_err(|e| e.to_string())?;
                Ok(json!({"written": to_rel, "slides": deck["slides"].as_array().map(|a| a.len()).unwrap_or(0)}))
            }
            "pdf" => {
                if to.extension().is_none_or(|e| e != "pdf") {
                    return Err("A PDF ends in .pdf.".into());
                }
                if let Some(src) = args["path"].as_str().filter(|p| !p.is_empty()) {
                    let src = ctx.path(src)?;
                    let soffice = super::tool(&["soffice"]).ok_or("Turning a .pptx into a PDF uses LibreOffice; install it, or give `deck` to print the HTML deck instead.")?;
                    let out = ctx.state.join("slides-pdf");
                    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
                    super::run(&soffice, &["--headless", "--convert-to", "pdf", "--outdir", &out.to_string_lossy(), &src.to_string_lossy()], &ctx.files).await?;
                    let made = out.join(src.with_extension("pdf").file_name().ok_or("No file name.")?);
                    std::fs::rename(&made, &to).or_else(|_| std::fs::copy(&made, &to).map(|_| ())).map_err(|e| e.to_string())?;
                    return Ok(json!({"written": to_rel, "from": "pptx"}));
                }
                let deck = check_deck(ctx, &args["deck"])?;
                let chrome = super::browser::chrome().ok_or("Printing the deck uses Google Chrome; install it, or make a .pptx and use LibreOffice.")?;
                let page = ctx.state.join("slides-print.html");
                std::fs::write(&page, html_deck(&deck)).map_err(|e| e.to_string())?;
                let pdf_flag = format!("--print-to-pdf={}", to.to_string_lossy());
                let url = format!("file://{}", page.to_string_lossy());
                super::run(chrome, &["--headless=new", "--disable-gpu", "--no-pdf-header-footer", &pdf_flag, &url], &ctx.files).await?;
                Ok(json!({"written": to_rel, "from": "html"}))
            }
            other => Err(format!("The slides engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Ctx {
        let dir = std::env::temp_dir().join(format!("px-slides-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Ctx { world: "w".into(), files: dir.clone(), state: dir.join(".parallax"), home: dir.join("home") }
    }

    #[test]
    fn a_deck_is_checked_before_anything_is_made() {
        let c = ctx();
        assert!(check_deck(&c, &json!({"slides": []})).is_err());
        assert!(check_deck(&c, &json!({"slides": [{"layout": "spiral"}]})).is_err());
        assert!(check_deck(&c, &json!({"slides": [{"layout": "image", "title": "x"}]})).is_err(), "an image slide needs its image");
        assert!(check_deck(&c, &json!({"slides": [{"layout": "bullets", "image": "missing.png"}]})).is_err());
        let ok = check_deck(&c, &json!({"title": "Q4", "slides": [{"title": "Plan", "bullets": ["a", "b"]}]})).unwrap();
        assert_eq!(ok["slides"][0]["layout"], "bullets");
        assert_eq!(ok["theme"], "dark");
    }

    #[test]
    fn the_html_deck_holds_every_slide_and_escapes_text() {
        let deck = json!({"title": "A <b> deck", "theme": "light", "slides": [{"layout": "title", "title": "Hello & welcome"}, {"layout": "bullets", "title": "Why", "bullets": ["one", "<script>"]}]});
        let h = html_deck(&deck);
        assert_eq!(h.matches("<section class=\"slide").count(), 2);
        assert!(h.contains("Hello &amp; welcome") && h.contains("&lt;script&gt;") && !h.contains("<li><script>"));
        assert!(h.contains("#FBFAF7"), "the light theme");
    }
}

#[cfg(test)]
mod live {
    use super::*;

    /// `cargo test -- --ignored live_slides`: makes a real .pptx (python-pptx, installed once), its PDF, and the HTML deck.
    #[tokio::test]
    #[ignore]
    async fn live_slides_make_pptx_pdf_and_html() {
        let dir = std::env::temp_dir().join(format!("px-slides-live-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ctx = Ctx { world: "w".into(), files: dir.clone(), state: dir.join(".parallax"), home: std::env::temp_dir().join("px-slides-home") };
        let deck = json!({"title": "Cookie Q4", "theme": "dark", "slides": [
            {"layout": "title", "title": "Cookie, Q4", "text": "A team of agents on your Mac"},
            {"layout": "bullets", "title": "What shipped", "bullets": ["Automatic skills", "Contractors", "The brain as the team's OS"], "notes": "Keep it short."},
            {"layout": "two_columns", "title": "Before / after", "left": ["One agent", "Manual skills"], "right": ["A team", "Skills that test themselves"]},
            {"layout": "quote", "text": "Motion means work.", "title": "Grok Bot's lesson"},
            {"layout": "closing", "title": "Thank you"}
        ]});
        let r = Slides.call(&ctx, "make", &json!({"deck": deck, "to": "deck/cookie.pptx"})).await.unwrap();
        println!("pptx: {r}");
        assert_eq!(r["slides"], 5);
        let pdf = Slides.call(&ctx, "pdf", &json!({"path": "deck/cookie.pptx", "to": "deck/cookie.pdf"})).await;
        println!("pdf from pptx: {pdf:?}");
        let html = Slides.call(&ctx, "html", &json!({"deck": deck, "to": "deck/cookie.html"})).await.unwrap();
        println!("html: {html}");
        let pdf2 = Slides.call(&ctx, "pdf", &json!({"deck": deck, "to": "deck/cookie-print.pdf"})).await;
        println!("pdf from html: {pdf2:?}");
        for f in ["deck/cookie.pptx", "deck/cookie.pdf", "deck/cookie.html", "deck/cookie-print.pdf"] {
            println!("  {f}: {} bytes", std::fs::metadata(dir.join(f)).map(|m| m.len()).unwrap_or(0));
        }
        std::fs::create_dir_all("/private/tmp/claude-501/-Users-naveen-Desktop-thinkingroot/e5dc43a2-1f8a-49ad-8256-c4073a907f3b/scratchpad/deck").ok();
        let _ = std::process::Command::new("cp").args(["-R", &dir.join("deck").to_string_lossy(), "/private/tmp/claude-501/-Users-naveen-Desktop-thinkingroot/e5dc43a2-1f8a-49ad-8256-c4073a907f3b/scratchpad/"]).status();
    }
}
