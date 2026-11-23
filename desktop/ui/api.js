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

  /** One agent in a window of its own. */
  async function openWindow(agent, title) {
    if (tauri) return tauri.core.invoke("open_window", { agent, title });
    const w = window.open(`${location.pathname}?agent=${encodeURIComponent(agent)}`, `cookie-${agent}`, "width=760,height=720");
    if (!w) throw "The browser blocked the new window.";
  }

  return { call, listen, reveal, openWindow, web: !tauri, signedIn: () => !!tauri || !!token };
})();
