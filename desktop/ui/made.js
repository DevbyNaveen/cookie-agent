// What an agent made: a small button beside its name opens a full page over the
// chat (like a PDF): its space, then everything it made, then what you gave it,
// as cards. One item can be pinned; it sits beside the name as its own button.
let madeFor = null;
let madeData = null;

const MADE_ICON = { image: "eye", video: "wave", audio: "wave", pdf: "file", sheet: "chart", document: "file", slides: "file", text: "file", archive: "folder", other: "file" };
const SPACE_PIN = "@space";

function madeOpenFor(id) { return id && madeFor === id && $("doc-view").dataset.made === id; }

function agoShort(secs) {
  const d = Date.now() / 1000 - secs;
  if (d < 60) return "just now";
  if (d < 3600) return `${Math.floor(d / 60)} min ago`;
  if (d < 86400) return `${Math.floor(d / 3600)} h ago`;
  if (d < 7 * 86400) return `${Math.floor(d / 86400)} d ago`;
  return new Date(secs * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

/** Open one item: its space, a picture, a page or PDF full-size, else its own app. */
async function openMade(agentId, path, name, fromList = false) {
  if (path === SPACE_PIN) { closePage(); madeFor = null; if (current?.id !== agentId) await openAgent(agentId); return openWorkspace(); }
  try {
    const f = await chatFile(agentId, path);
    if (f.kind === "image" && f.data) return lightbox(`data:${f.media_type};base64,${f.data}`, name);
    if (f.text != null || (f.kind === "pdf" && f.data)) {
      openPage(agentId, f, name);
      delete $("doc-view").dataset.made;
      if (fromList) {
        // Back to the list it came from.
        const back = el("button", "pill doc-btn made-back");
        back.type = "button";
        back.append(icon("layers"), el("span", null, "All it made"));
        back.onclick = () => openMadePanel();
        $("doc-view").querySelector(".doc-acts")?.prepend(back);
      }
      return;
    }
    if (Api.web) return toast("Open it on the Mac", `${name} opens in its own app there.`, "");
    await (f.openable ? Api.openFile(agentId, f.path) : Api.openFile(agentId, f.path, true));
  } catch (e) { toast("Couldn't open it", String(e), "error"); }
}

async function setPin(agentId, path) {
  try {
    const pin = await call("agent_pin", { id: agentId, path });
    if (madeData && madeFor === agentId) madeData.pin = pin;
    paintPin(agentId, pin);
    if (madeOpenFor(agentId)) renderMade();
  } catch (e) { toast("Couldn't pin it", String(e), "error"); }
}

/** The pinned item beside the agent's name. */
function paintPin(agentId, pin) {
  const b = $("pin-pill");
  if (current?.id !== agentId) return;
  b.hidden = !pin;
  if (!pin) return;
  const name = pin === SPACE_PIN ? "Space" : pin.split("/").pop().replace(/\.(md|markdown|txt|html)$/i, "");
  const ic = pin === SPACE_PIN ? "blocks" : (/\.(png|jpe?g|gif|webp|heic)$/i.test(pin) ? "eye" : "file");
  b.replaceChildren(icon(ic), el("span", "pin-name", name.length > 22 ? name.slice(0, 21) + "…" : name));
  b.title = `Pinned: ${pin === SPACE_PIN ? "its space" : pin}`;
  b.onclick = () => openMade(agentId, pin, name);
}

async function loadPin(agentId) {
  $("pin-pill").hidden = true;
  try { const v = await call("agent_files", { id: agentId }); paintPin(agentId, v.pin); } catch {}
}

function madeCard(agentId, item, pinned) {
  const card = el("div", "made-card" + (pinned ? " pinned" : "") + (item.path === SPACE_PIN ? " space" : ""));
  const open = el("button", "made-open");
  open.type = "button";
  const ic = el("span", `made-ic k-${item.kind}`);
  ic.append(icon(item.path === SPACE_PIN ? "blocks" : MADE_ICON[item.kind] ?? "file"));
  const t = el("span", "made-text");
  t.append(el("span", "made-name", item.name), el("small", null, item.sub));
  open.append(ic, t);
  open.onclick = () => openMade(agentId, item.path, item.name, true);
  const pin = el("button", "round soft made-pin" + (pinned ? " on" : ""));
  pin.type = "button";
  pin.title = pinned ? "Unpin" : "Pin beside its name";
  pin.setAttribute("aria-label", pinned ? `Unpin ${item.name}` : `Pin ${item.name}`);
  pin.setAttribute("aria-pressed", String(pinned));
  pin.append(icon("pin"));
  pin.onclick = (e) => { e.stopPropagation(); setPin(agentId, pinned ? null : item.path); };
  card.append(open, pin);
  return card;
}

function renderMade() {
  const agentId = madeFor;
  const a = agentById(agentId) ?? current;
  const v = $("doc-view");
  const head = el("div", "doc-head");
  const pill = el("div", "pill doc-pill");
  pill.append(icon("layers"), el("span", null, `Made by ${a?.name ?? "it"}`));
  const acts = el("div", "doc-acts");
  const x = el("button", "round soft doc-x");
  x.type = "button";
  x.setAttribute("aria-label", "Close");
  x.append(icon("x"));
  x.onclick = () => { madeFor = null; $("made-btn").classList.remove("on"); closePage(); };
  acts.append(x);
  head.append(pill, acts);
  const body = el("div", "doc-body made-page");
  const d = madeData;
  if (!d) body.append(el("p", "made-empty", "Loading…"));
  else {
    const made = d.files.filter((f) => !f.given), given = d.files.filter((f) => f.given);
    const sub = (f) => `${FILE_KIND[f.kind] ?? "File"} · ${humanSize(f.size)} · ${agoShort(f.modified)}`;
    const section = (title, items) => {
      if (!items.length) return;
      body.append(el("h3", "made-title", title));
      const g = el("div", "made-grid");
      for (const it of items) g.append(madeCard(agentId, it, d.pin === it.path));
      body.append(g);
    };
    if (d.space) section("Its space", [{ path: SPACE_PIN, name: "Space", kind: "other", sub: `${d.space.blocks} block${d.space.blocks === 1 ? "" : "s"} · its own software` }]);
    section("Made", made.map((f) => ({ ...f, sub: (f.path.includes("/") ? f.path.split("/").slice(0, -1).join("/") + " · " : "") + sub(f) })));
    section("You gave it", given.map((f) => ({ ...f, sub: sub(f) })));
    if (!d.space && !d.files.length) body.append(el("p", "made-empty", `Nothing yet. Pages, PDFs, sheets and pictures ${a?.name ?? "it"} makes show up here.`));
    if (d.more) body.append(el("p", "made-empty", `And ${d.more} more in its folder.`));
    if (d.space || d.files.length) body.append(el("p", "made-hint", "Pin one to keep it beside the name."));
  }
  v.replaceChildren(head, body);
  v.dataset.made = agentId;
  if (v.hidden) {
    v.hidden = false;
    $("chat").classList.add("doc-open");
    requestAnimationFrame(() => v.classList.add("open"));
  }
}

async function openMadePanel() {
  if (!current) return;
  const id = current.id;
  closeProfile();
  madeFor = id;
  madeData = null;
  $("made-btn").classList.add("on");
  renderMade();
  try { madeData = await call("agent_files", { id }); } catch (e) { toast("Couldn't list what it made", String(e), "error"); return; }
  if (madeFor !== id) return;
  renderMade();
  paintPin(id, madeData.pin);
}

$("made-btn").onclick = () => (madeOpenFor(current?.id) ? ($("made-btn").classList.remove("on"), (madeFor = null), closePage()) : openMadePanel());

/** When the agent finishes something, the open list catches up. */
function refreshMade(agentId) {
  if (madeOpenFor(agentId)) call("agent_files", { id: agentId }).then((v) => { if (madeFor === agentId) { madeData = v; renderMade(); } }).catch(() => {});
}
