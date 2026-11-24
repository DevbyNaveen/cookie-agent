//! PDF: read the text, count pages, merge files, keep some pages.
//!
//! Text comes from `pdftotext` (Poppler) when it is installed, else from the
//! PDF itself (`lopdf`). Merging and splitting are done on the file's own
//! objects (`lopdf`), pages kept in order.

use std::collections::BTreeMap;

use async_trait::async_trait;
use lopdf::{Document as Doc, Object, ObjectId};
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Pdf;

/// Join PDFs into one, pages in the order given.
pub fn merge(docs: Vec<Doc>) -> Result<Doc, String> {
    let mut max_id = 1;
    let mut pages: Vec<(ObjectId, Object)> = Vec::new();
    let mut objects: BTreeMap<ObjectId, Object> = BTreeMap::new();
    for mut d in docs {
        d.renumber_objects_with(max_id);
        max_id = d.max_id + 1;
        for (_, id) in d.get_pages() {
            let mut page = d.get_object(id).map_err(|e| e.to_string())?.as_dict().map_err(|e| e.to_string())?.clone();
            // What a page inherits from its page tree, written onto the page: the tree is replaced.
            for key in [&b"Resources"[..], b"MediaBox", b"CropBox", b"Rotate"] {
                if page.has(key) {
                    continue;
                }
                let mut parent = page.get(b"Parent").and_then(|p| p.as_reference()).ok();
                while let Some(pid) = parent {
                    let Ok(pd) = d.get_object(pid).and_then(|o| o.as_dict()) else { break };
                    if let Ok(v) = pd.get(key) {
                        page.set(key.to_vec(), v.clone());
                        break;
                    }
                    parent = pd.get(b"Parent").and_then(|p| p.as_reference()).ok();
                }
            }
            pages.push((id, Object::Dictionary(page)));
        }
        objects.extend(d.objects);
    }
    let mut out = Doc::with_version("1.5");
    let mut catalog: Option<(ObjectId, Object)> = None;
    let mut tree: Option<(ObjectId, Object)> = None;
    for (id, obj) in &objects {
        match obj.type_name().unwrap_or_default() {
            "Catalog" => catalog = Some((catalog.as_ref().map(|c| c.0).unwrap_or(*id), obj.clone())),
            "Pages" => {
                if let Ok(d) = obj.as_dict() {
                    let mut d = d.clone();
                    if let Some((_, old)) = &tree {
                        if let Ok(o) = old.as_dict() {
                            d.extend(o);
                        }
                    }
                    tree = Some((tree.as_ref().map(|t| t.0).unwrap_or(*id), Object::Dictionary(d)));
                }
            }
            "Page" | "Outlines" | "Outline" => {}
            _ => {
                out.objects.insert(*id, obj.clone());
            }
        }
    }
    let (tree_id, tree_obj) = tree.ok_or("No page tree in these files.")?;
    let (cat_id, cat_obj) = catalog.ok_or("No catalog in these files.")?;
    for (id, obj) in &pages {
        if let Ok(d) = obj.as_dict() {
            let mut d = d.clone();
            d.set("Parent", tree_id);
            out.objects.insert(*id, Object::Dictionary(d));
        }
    }
    let mut t = tree_obj.as_dict().map_err(|e| e.to_string())?.clone();
    t.set("Count", pages.len() as u32);
    t.set("Kids", pages.iter().map(|(id, _)| Object::Reference(*id)).collect::<Vec<_>>());
    out.objects.insert(tree_id, Object::Dictionary(t));
    let mut c = cat_obj.as_dict().map_err(|e| e.to_string())?.clone();
    c.set("Pages", tree_id);
    c.remove(b"Outlines");
    out.objects.insert(cat_id, Object::Dictionary(c));
    out.trailer.set("Root", cat_id);
    out.max_id = out.objects.len() as u32;
    out.renumber_objects();
    out.compress();
    Ok(out)
}

/// "1-3,5" → [1, 2, 3, 5].
pub fn page_list(spec: &str, count: u32) -> Result<Vec<u32>, String> {
    let mut out = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (a, b) = part.split_once('-').unwrap_or((part, part));
        let (a, b): (u32, u32) = (a.trim().parse().map_err(|_| format!("“{part}” isn't pages"))?, b.trim().parse().map_err(|_| format!("“{part}” isn't pages"))?);
        if a == 0 || b < a || b > count {
            return Err(format!("Pages {part}: the file has {count}."));
        }
        out.extend(a..=b);
    }
    if out.is_empty() {
        return Err("Say which pages, e.g. \"1-3,5\".".into());
    }
    Ok(out)
}

#[async_trait]
impl Engine for Pdf {
    fn name(&self) -> &'static str {
        "pdf"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new("pdf", "text", "The text of a PDF (all pages, or `pages` like \"1-3\").", json!({"type": "object", "properties": {"path": p, "pages": p}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("pdf", "info", "How many pages a PDF has.", json!({"type": "object", "properties": {"path": p}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("pdf", "merge", "Join PDFs into one, in order.", json!({"type": "object", "properties": {"paths": {"type": "array", "items": p}, "to": p}, "required": ["paths", "to"]}), Effect::Local),
            ActionSpec::new("pdf", "keep_pages", "Write a new PDF with only some pages (\"1-3,5\").", json!({"type": "object", "properties": {"path": p, "pages": p, "to": p}, "required": ["path", "pages", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let load = |rel: &str| -> Result<Doc, String> { Doc::load(ctx.path(rel)?).map_err(|e| format!("{rel} isn't a readable PDF: {e}")) };
        match action {
            "info" => Ok(json!({"pages": load(s(args, "path")?)?.get_pages().len()})),
            "text" => {
                let path = s(args, "path")?;
                if let Some(pt) = super::tool(&["pdftotext"]) {
                    let full = ctx.path(path)?;
                    let mut a: Vec<String> = vec!["-layout".into()];
                    if let Some(range) = args["pages"].as_str() {
                        let count = load(path)?.get_pages().len() as u32;
                        let list = page_list(range, count)?;
                        a.extend(["-f".into(), list[0].to_string(), "-l".into(), list[list.len() - 1].to_string()]);
                    }
                    a.extend([full.to_string_lossy().to_string(), "-".into()]);
                    let refs: Vec<&str> = a.iter().map(String::as_str).collect();
                    let text = super::run(&pt, &refs, &ctx.files).await?;
                    return Ok(json!({"text": crate::util::clip(&text, 200_000), "by": "pdftotext"}));
                }
                let d = load(path)?;
                let count = d.get_pages().len() as u32;
                let pages = match args["pages"].as_str() { Some(r) => page_list(r, count)?, None => (1..=count).collect() };
                let text = d.extract_text(&pages).map_err(|e| e.to_string())?;
                Ok(json!({"text": crate::util::clip(&text, 200_000), "by": "lopdf"}))
            }
            "merge" => {
                let paths: Vec<String> = serde_json::from_value(args["paths"].clone()).map_err(|e| e.to_string())?;
                if paths.len() < 2 {
                    return Err("Merge needs two PDFs or more.".into());
                }
                let docs = paths.iter().map(|p| load(p)).collect::<Result<Vec<_>, _>>()?;
                let mut out = merge(docs)?;
                let to = s(args, "to")?;
                out.save(ctx.path(to)?).map_err(|e| e.to_string())?;
                Ok(json!({"written": to, "pages": out.get_pages().len()}))
            }
            "keep_pages" => {
                let mut d = load(s(args, "path")?)?;
                let count = d.get_pages().len() as u32;
                let keep = page_list(s(args, "pages")?, count)?;
                let drop: Vec<u32> = (1..=count).filter(|p| !keep.contains(p)).collect();
                d.delete_pages(&drop);
                d.prune_objects();
                let to = s(args, "to")?;
                d.save(ctx.path(to)?).map_err(|e| e.to_string())?;
                Ok(json!({"written": to, "pages": d.get_pages().len()}))
            }
            other => Err(format!("The pdf engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
pub(crate) fn tiny_pdf(text: &str, pages: usize) -> Doc {
    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Stream};
    let mut doc = Doc::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {"Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Courier"});
    let resources_id = doc.add_object(dictionary! {"Font" => dictionary! {"F1" => font_id}});
    let mut kids = Vec::new();
    for i in 0..pages {
        let content = Content { operations: vec![Operation::new("BT", vec![]), Operation::new("Tf", vec!["F1".into(), 24.into()]), Operation::new("Td", vec![100.into(), 600.into()]), Operation::new("Tj", vec![Object::string_literal(format!("{text} {}", i + 1))]), Operation::new("ET", vec![])] };
        let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
        let page_id = doc.add_object(dictionary! {"Type" => "Page", "Parent" => pages_id, "Contents" => content_id});
        kids.push(Object::Reference(page_id));
    }
    doc.objects.insert(pages_id, Object::Dictionary(dictionary! {"Type" => "Pages", "Kids" => kids, "Count" => pages as u32, "Resources" => resources_id, "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()]}));
    let catalog_id = doc.add_object(dictionary! {"Type" => "Catalog", "Pages" => pages_id});
    doc.trailer.set("Root", catalog_id);
    doc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn merge_keep_and_read() {
        let d = tempfile::tempdir().unwrap();
        let ctx = Ctx { world: "w".into(), files: d.path().to_path_buf(), state: d.path().join(".parallax"), home: d.path().join("home") };
        tiny_pdf("alpha", 2).save(d.path().join("a.pdf")).unwrap();
        tiny_pdf("beta", 1).save(d.path().join("b.pdf")).unwrap();
        let m = Pdf.call(&ctx, "merge", &json!({"paths": ["a.pdf", "b.pdf"], "to": "ab.pdf"})).await.unwrap();
        assert_eq!(m["pages"], 3);
        let k = Pdf.call(&ctx, "keep_pages", &json!({"path": "ab.pdf", "pages": "1,3", "to": "k.pdf"})).await.unwrap();
        assert_eq!(k["pages"], 2);
        let t = Pdf.call(&ctx, "text", &json!({"path": "k.pdf"})).await.unwrap();
        let text = t["text"].as_str().unwrap();
        assert!(text.contains("alpha 1") && text.contains("beta 1") && !text.contains("alpha 2"), "{text}");
        assert!(page_list("2-9", 3).is_err());
    }
}
