// Settings → Privacy → Your files: how far agents with the Files permission see
// beyond their own folder. Three kinds, chosen here; every change to a file of
// yours asks first, keeps the old version, and secrets are never opened.

const ACCESS_KINDS = [
  { id: "own", title: "Only their own folder", note: "Agents work on files you copy in. Nothing else on your Mac is visible.", icon: "folder" },
  { id: "folders", title: "Folders you choose", note: "They can read the folders you pick here, and nothing outside them.", icon: "pin", tag: "Recommended" },
  { id: "home", title: "Your home folder", note: "Everything in your home folder, except ~/Library (mail, messages, app data) and where secrets live.", icon: "globe" },
];

const privacyPane = SETTINGS.privacy;
SETTINGS.privacy = async () => {
  const parts = await privacyPane();
  const access = await call("access").catch(() => null);
  if (!access) return parts;
  const section = [el("h3", "group-title", "Your files")];

  const kinds = el("div", "access-kinds");
  kinds.setAttribute("role", "radiogroup");
  kinds.setAttribute("aria-label", "What agents can see on your Mac");
  for (const k of ACCESS_KINDS) {
    const b = el("button", "access-kind" + (access.level === k.id ? " on" : ""));
    b.type = "button";
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", String(access.level === k.id));
    const ic = el("span", "access-ic"); ic.append(icon(k.icon));
    const t = el("div", "row-text");
    const title = el("span", null, k.title);
    if (k.tag) title.append(el("em", "access-tag", k.tag));
    t.append(title, el("small", null, k.note));
    const dot = el("span", "access-dot");
    b.append(ic, t, dot);
    b.onclick = async () => {
      if (access.level === k.id) return;
      if (k.id === "folders" && !access.folders.length) {
        const f = await chooseFolder();
        if (!f) return;
        return saveAccess("folders", [f]);
      }
      saveAccess(k.id, access.folders);
    };
    kinds.append(b);
  }
  section.push(kinds);

  if (access.level === "folders") {
    const list = el("div", "group");
    for (const f of access.folders) {
      const remove = button("Remove", "quiet small", () => {
        const rest = access.folders.filter((x) => x !== f);
        return rest.length ? saveAccess("folders", rest) : saveAccess("own", []);
      });
      const row = setRow(f, null, remove);
      row.classList.add("access-folder");
      list.append(row);
    }
    list.append(setRow("Add a folder", "Agents see it and everything inside it.", button("Choose…", "small", async () => {
      const f = await chooseFolder();
      if (f) await saveAccess("folders", [...access.folders, f]);
    })));
    section.push(list);
  }

  const rules = el("div", "group");
  rules.append(
    setRow("Every change asks you first", "Creating or replacing a file of yours always waits for your yes, however good the agent's record. The old version is kept so you can put it back.", el("span", "status-pill ok", "Always")),
    setRow("Secrets are never opened", ".ssh, keychains, cloud credentials, .env files, private keys, ~/Library and Cookie's own data are off limits.", el("span", "status-pill ok", "Always")),
    setRow("Nothing is deleted or moved", "Agents can read, search and write; they can't delete or move your files.", el("span", "status-pill ok", "Always")),
    setRow("People outside never see them", "Contacts, rooms and other people's agents talking to yours can't reach your files.", el("span", "status-pill ok", "Always")),
  );
  section.push(rules);
  // Right after "Where your data lives": what agents can reach is the first privacy question.
  parts.splice(3, 0, ...section);
  return parts;
};

async function chooseFolder() {
  if (!Api.web) {
    try { return await Api.pickFolder(); } catch (e) { toast("Couldn't open the chooser", String(e), "error"); return null; }
  }
  const p = prompt("Full path of a folder agents may see (for example ~/Documents/Clients):");
  return p?.trim() || null;
}

async function saveAccess(level, folders) {
  try {
    await call("set_access", { level, folders });
    const k = ACCESS_KINDS.find((x) => x.id === level);
    toast("Agents now see", k ? k.title.toLowerCase() : level, "good");
  } catch (e) { toast("Couldn't change it", String(e), "error"); }
  refreshSettings();
}
