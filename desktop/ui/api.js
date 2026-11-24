// One way to talk to the team, wherever this page runs: inside the desktop
// app (Tauri) or in a browser opened from a runner's link (HTTP + events).
const Api = (() => {
  const tauri = window.__TAURI__;
  let token = null;
  if (!tauri) {
    const m = location.hash.match(/token=([0-9a-f]+)/);
    if (m) {
      token = m[1];
      try { localStorage.setItem("cookie.runnerToken", token); } catch {}
      history.replaceState(null, "", location.pathname + location.search);
    } else {
      try { token = localStorage.getItem("cookie.runnerToken"); } catch {}
    }
  }

  async function call(cmd, args = {}) {
    if (tauri) return tauri.core.invoke("call", { cmd, args });
    const r = await fetch(`/api/${cmd}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token ?? ""}` },
      body: JSON.stringify(args),
    });
    const body = await r.json().catch(() => ({ error: `The runner answered ${r.status}.` }));
    if (!r.ok || "error" in body) throw body.error ?? `The runner answered ${r.status}.`;
    return body.ok;
  }

  function listen(fn) {
    if (tauri) return tauri.event.listen("team", (e) => fn(e.payload));
    let es;
    const open = () => {
      es = new EventSource(`/events?token=${encodeURIComponent(token ?? "")}`);
      es.onmessage = (m) => { try { fn(JSON.parse(m.data)); } catch {} };
      es.onerror = () => { es.close(); setTimeout(open, 3000); };
    };
    open();
  }

  async function reveal(path) {
    if (!tauri) throw "Folders open only on the runner's own computer.";
    return tauri.core.invoke("reveal", { path });
  }

  /** An https page in the person's browser (the Enkeon Console, to pair). */
  async function openUrl(url) {
    if (!/^https:\/\//.test(url)) throw "Cookie opens only https pages.";
    if (tauri) return tauri.core.invoke("open_url", { url });
    window.open(url, "_blank", "noopener");
  }

  /** One agent in a window of its own. */
  async function openWindow(agent, title) {
    if (tauri) return tauri.core.invoke("open_window", { agent, title });
    const w = window.open(`${location.pathname}?agent=${encodeURIComponent(agent)}`, `cookie-${agent}`, "width=760,height=720");
    if (!w) throw "The browser blocked the new window.";
  }

  /** The Mac's own folder chooser; null when cancelled or in a browser. */
  async function pickFolder() {
    if (!tauri) return null;
    return tauri.core.invoke("pick_folder");
  }

  /** A job link Cookie sent (`/j/<token>` → `#link=`): asks for the PIN, then signs this browser in. */
  const pendingLink = !tauri ? location.hash.match(/link=([0-9a-f]+)/)?.[1] ?? null : null;
  async function openLink(pin) {
    const r = await fetch("/link/open", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ link: pendingLink, pin }) });
    const body = await r.json().catch(() => ({ error: `The runner answered ${r.status}.` }));
    if (!r.ok || "error" in body) throw body.error ?? `The runner answered ${r.status}.`;
    token = body.ok.session;
    try { localStorage.setItem("cookie.runnerToken", token); } catch {}
    history.replaceState(null, "", location.pathname + location.search);
    return body.ok;
  }

  return { call, listen, reveal, openUrl, openWindow, pickFolder, openLink, pendingLink, web: !tauri, signedIn: () => !!tauri || !!token };
})();
