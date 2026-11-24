// Cookie's own dropdown, everywhere: every <select> in the app becomes a button
// that opens Cookie's menu (the same look as the ••• and right-click menus)
// instead of the system's picker. The real <select> stays underneath, hidden,
// so values, `onchange` handlers and forms work exactly as before.
(() => {
  const SVG = "http://www.w3.org/2000/svg";
  let open = null; // { select, menu, button, items, at }

  const node = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  function svg(path, cls) {
    const s = document.createElementNS(SVG, "svg");
    s.setAttribute("viewBox", "0 0 24 24");
    if (cls) s.setAttribute("class", cls);
    s.innerHTML = path;
    return s;
  }
  const chevron = () => svg('<path d="M7 10l5 5 5-5"/>', "dd-chev");
  const check = () => svg('<path d="M5 12.5l4.5 4.5L19 7.5"/>', "dd-check");

  function label(select) {
    const o = select.selectedOptions[0] ?? select.options[0];
    return o ? o.textContent : "";
  }

  function refresh(select) {
    const w = select._dd;
    if (!w) return;
    w.text.textContent = label(select);
    w.button.disabled = select.disabled;
    w.button.title = select.title || "";
    // A hidden select hides its button too.
    w.wrap.hidden = select.hidden;
  }

  function enhance(select) {
    if (select._dd || select.multiple || select.dataset.native != null) return;
    const wrap = node("span", "dd" + (select.classList.contains("wide") ? " dd-wide" : ""));
    const button = node("button", "dd-btn " + select.className);
    button.type = "button";
    button.setAttribute("aria-haspopup", "listbox");
    button.setAttribute("aria-expanded", "false");
    const aria = select.getAttribute("aria-label");
    if (aria) button.setAttribute("aria-label", aria);
    const text = node("span", "dd-text");
    button.append(text, chevron());
    select.replaceWith(wrap);
    wrap.append(button, select);
    select.classList.add("dd-native");
    select.tabIndex = -1;
    select.setAttribute("aria-hidden", "true");
    select._dd = { wrap, button, text };

    // Code that sets `.value` directly still updates the label.
    const proto = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
    Object.defineProperty(select, "value", { configurable: true, get() { return proto.get.call(this); }, set(v) { proto.set.call(this, v); refresh(this); } });
    select.addEventListener("change", () => refresh(select));
    new MutationObserver(() => refresh(select)).observe(select, { childList: true, subtree: true, attributes: true, attributeFilter: ["disabled", "hidden"] });

    button.onclick = (e) => { e.stopPropagation(); open?.select === select ? close() : show(select); };
    button.onkeydown = (e) => {
      if (["ArrowDown", "ArrowUp", "Enter", " "].includes(e.key)) { e.preventDefault(); show(select); }
    };
    refresh(select);
  }

  function show(select) {
    close();
    const { button } = select._dd;
    const host = button.closest("dialog") ?? document.body;
    const menu = node("div", "pop menu dd-menu");
    menu.setAttribute("role", "listbox");
    const items = [];
    for (const o of select.options) {
      if (o.hidden) continue;
      const b = node("button", "dd-item" + (o.selected ? " on" : ""));
      b.type = "button";
      b.setAttribute("role", "option");
      b.setAttribute("aria-selected", String(o.selected));
      b.disabled = o.disabled;
      b.append(o.selected ? check() : node("i", "dd-gap"), node("span", null, o.textContent));
      b.onclick = (e) => { e.stopPropagation(); pick(select, o.value); };
      b.onmousemove = () => focusItem(items.indexOf(b));
      items.push(b);
      menu.append(b);
    }
    host.append(menu);
    // Beside the button, inside the window: below it when there's room, else above,
    // its right edge on the button's. Placed, then measured and corrected, because a
    // dialog may or may not be what `position: fixed` is measured from (it differs by engine).
    const r = button.getBoundingClientRect();
    menu.style.animation = "none"; // measure it at rest, not mid-animation
    menu.style.position = "fixed";
    menu.style.right = "auto";
    menu.style.minWidth = r.width + "px";
    const w = menu.offsetWidth, h = menu.offsetHeight;
    const below = r.bottom + 6 + h <= innerHeight - 8;
    const want = { left: Math.min(Math.max(8, r.right - w), innerWidth - w - 8), top: below ? r.bottom + 6 : Math.max(8, r.top - 6 - h) };
    menu.style.left = want.left + "px";
    menu.style.top = want.top + "px";
    const got = menu.getBoundingClientRect();
    menu.style.left = want.left + (want.left - got.left) + "px";
    menu.style.top = want.top + (want.top - got.top) + "px";
    requestAnimationFrame(() => { menu.style.animation = ""; });
    menu.style.transformOrigin = below ? "top right" : "bottom right";
    button.setAttribute("aria-expanded", "true");
    button.classList.add("open");
    open = { select, menu, button, items, at: Math.max(0, [...select.options].filter((o) => !o.hidden).findIndex((o) => o.selected)) };
    focusItem(open.at);
  }

  function focusItem(i) {
    if (!open || !open.items.length) return;
    open.at = (i + open.items.length) % open.items.length;
    open.items.forEach((b, k) => b.classList.toggle("hot", k === open.at));
    open.items[open.at].focus({ preventScroll: true });
    open.items[open.at].scrollIntoView({ block: "nearest" });
  }

  function pick(select, value) {
    const before = select.value;
    close();
    if (value !== before) {
      select.value = value;
      select.dispatchEvent(new Event("input", { bubbles: true }));
      select.dispatchEvent(new Event("change", { bubbles: true }));
    }
    select._dd.button.focus();
  }

  function close() {
    if (!open) return;
    open.menu.remove();
    open.button.setAttribute("aria-expanded", "false");
    open.button.classList.remove("open");
    open = null;
  }

  document.addEventListener("click", (e) => { if (open && !open.menu.contains(e.target)) close(); }, true);
  document.addEventListener("keydown", (e) => {
    if (!open) return;
    const visible = [...open.select.options].filter((o) => !o.hidden);
    if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); const b = open.button; close(); b.focus(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); focusItem(open.at + 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); focusItem(open.at - 1); }
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); const o = visible[open.at]; if (o && !o.disabled) pick(open.select, o.value); }
    else if (e.key === "Tab") close();
    else if (e.key.length === 1) { // type to jump
      const k = e.key.toLowerCase();
      const i = visible.findIndex((o, n) => n > open.at && o.textContent.trim().toLowerCase().startsWith(k));
      const j = i >= 0 ? i : visible.findIndex((o) => o.textContent.trim().toLowerCase().startsWith(k));
      if (j >= 0) focusItem(j);
    }
  }, true);
  addEventListener("resize", close);
  document.addEventListener("scroll", (e) => { if (open && !open.menu.contains(e.target)) close(); }, true);

  // Every select, now and later.
  const scan = (root) => { if (root.tagName === "SELECT") enhance(root); root.querySelectorAll?.("select").forEach(enhance); };
  scan(document.body);
  new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) if (n.nodeType === 1) scan(n); }).observe(document.body, { childList: true, subtree: true });
})();
