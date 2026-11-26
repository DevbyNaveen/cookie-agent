# Cookie guide

## main-window | The main window
> The window: a left column of agent faces, the open chat on the right, and your name and buttons at the bottom of the column.
The left column (the rail) lists the person's agents, each showing its face, its name, a preview of its last message or what it is doing now, and the time.

- **Order.** Pinned agents come first, then everything by latest activity ("Recent"), then the named sections in name order.
- **Badges.** An amber number means it needs the person's yes or an answer. A green number counts unread messages. A "probation" tag and a pin mark can also show.
- **Top buttons.** The search button ("Search agents") filters by name or job. The + button ("Hire an agent") opens hiring.
- **Needs you.** The "Needs you" chip appears when anything waits for the person. Clicking it shows only those agents.
- **Bottom of the column.** Your initials or photo and your name open the account menu. There are also buttons for Connect apps, Network (only shown once a relay is set) and a small + to hire.
- **Resizing.** Drag the column's edge to resize it. Drag it narrow to fold it down to faces only; hovering a face then shows its name and job. Double-click the edge, or press ⌘\, to fold or unfold it.
- **First open.** On opening, Cookie shows the chat that most recently needs the person, or else the most recent one.

The app's Dock icon shows the count of things waiting.

## sidebar-menus | Account menu and arranging agents
> Your name at the bottom opens the account menu; right-clicking an agent pins it, files it in a section, hides it, opens a new window or deletes it.
**Account menu.** Click your name or initials at the bottom of the left column. It shows your name and your Cookie Network address, with a copy button. The items are:
- Show sidebar (⌘\), only while the column is folded.
- **Change your photo:** shows wherever you appear in Cookie. Settings → General also has Add/Change photo and Remove.
- **Connect apps.**
- **Open Cookie's folder:** opens it in Finder.
- **Settings** (⌘,).

**Agent row menu.** Right-click an agent's row (or use the context-menu key, or Shift+F10). The items are:
- **Pin / Unpin.**
- **Move to new section / Move to another section:** this also unpins the agent. **Take out of "…"** removes it from a section.
- **Mark as read / Mark as unread.**
- **New window:** just this conversation, in its own window.
- **Copy agent ID.**
- **Hide from sidebar / Show in sidebar:** hidden agents wait behind "Hidden (n)", and search still finds them.
- **Delete:** opens the Fire dialog.

The sidebar arrangement is the person's own; agents have no tool to change it.

## cookie-main-agent | Cookie, the main agent
> Cookie (id "cookie", marked with a small star) is the front door: it helps directly, hands work to teammates, and is the only agent that can hire.
Cookie is the agent every team starts with. In the list its face carries a small star ("Cookie: your main agent"). It starts with the default permissions plus "Use this Mac".

**What it does**
- It helps with anything itself.
- It hands specialist work to a teammate by @address with the `message` tool, writing the message itself.
- It checks the team first with `team_overview`, which shows each agent's job, @address, whether it is busy, and what is pending.
- When the same kind of work keeps coming and nobody covers it, it suggests a hire.
- It reports what a teammate says about itself as that teammate's word, not as checked fact.

**What only Cookie has**
- The tools `team_overview` and `hire_agent`.
- Its chat's desk also shows team-wide items, such as Scout suggestions.

**What can be changed**
Cookie can't be fired or retired: its profile says "Cookie stays: it's your front door." The person can change its model and what it can use, put it to sleep, or hide it from the sidebar.

## hiring | Hiring an agent
> The Hire page (+ button or ⌘N) shows starter agents and "Your own"; picking one opens the hire sheet with name, one job, model and a look.
Open the Hire page with the + button, "Hire an agent", or ⌘N. With no agents yet the page is titled "Build your team".

**Starters**
Inbox Triage, Research Scout, Chief of Staff, Gym Trainer (it "Comes with its own software": a plan, workout log, body tracker, progress chart and check-in form), Writing Desk, Lead Pipeline Desk, Invoice Chaser, Meeting Notes, Daily Brief, Travel Planner and Learning Coach. A starter already hired is marked "Hired", and clicking it opens that agent. The last card, **Your own**, starts blank.

**The hire sheet**
- **Pick a look:** one face per shape. "More colours" deals new colours.
- **Name:** up to 40 characters.
- **Its one job:** up to 400 characters. This is its instructions.
- **Model:** written as provider:model, with suggestions.
- **Start from:** only shown when there is a handover note or a retired agent's archive. It offers "Start fresh", "Everything X learned…", or a handover note.
- Click **Hire <name>**. With no model key, it says "Add a model key in Settings → Models first."

**After hiring**
A new hire starts with files in its own folder, the web, memory and the person's apps. Cookie then picks its skills and tests them for it.

**What Cookie can do itself**
Cookie can hire with `hire_agent`. It takes a name (2–40 characters), a job (at least 12 characters), a brief and an optional model, which defaults to Cookie's own. The person approves the hire first. Agents hired this way start with no probation.

## chat | Each agent's chat
> Click an agent to open its chat: its intro, the conversation, live status while it works, cards for approvals and questions, and the composer below.
A chat opens with the agent's face, name and job, then "Hired <date>". If the agent is on probation, a note follows saying changes it tries are recorded, not made.

**What the chat shows**
- **Replies** render Markdown. They can include pictures, recordings, videos, file cards (Open, Show in Finder), document cards, boards, charts, flow diagrams and forms.
- **Message actions:** hovering a message shows Copy and Read aloud.
- **Pictures from the web** load only when clicked ("Show image from …"). Wikimedia Commons pictures show at once.
- **Other conversations:** when the agent talked with another agent, a pill like "2 messages with Writer" opens that conversation.
- **Your bubbles** take the agent's colour.

**The header pills**
- The agent's name opens its profile.
- The layers button opens "What it made".
- A pinned item may show beside the name.
- The **⋯** menu has:
  - **Undo its last changes:** puts its folder back to before its last changed checkpoint, after a confirm list.
  - **Copy conversation.**
  - **Fire agent.**

Unsent text is kept per agent when switching chats.

## composer | The composer: typing and sending
> Type in the Message box and press Enter to send (Shift+Enter for a new line, or ⌘↵ if set); Arrow Up in an empty box brings back your last message.
The composer sits at the bottom of a chat. Its placeholder reads "Message <name>".

**Sending**
- Enter sends and Shift+Enter makes a new line. With "Send with ⌘↵" on (Settings → General), Enter makes a new line and ⌘↵ sends.
- Arrow Up in an empty box refills your last message.

**The round button on the right changes role:**
- **Box empty, agent idle:** it is the voice-chat button ("Talk with <name>").
- **Text typed:** ↑ sends.
- **Agent working, box empty:** ■ stops the agent.
- **Agent working, text typed:** the text is added to the job in flight (see stop-and-steps).

**Before the first message**
In a chat the person hasn't written in yet, suggestion buttons appear above the box. They are the starters the agent wrote when hired, or else three generic ones: "Where should we start?", "First step: …" and "What do you need from me?". Clicking one fills the box.

Under the box sit two chips: permissions on the left and model on the right.

## attachments | Adding files, photos, folders and apps (+ menu)
> The + button offers "Add files or photos" (⌘U), "Add folder" and "Connect apps"; you can also drag files in or paste images.
Click **+** left of the message box.

**Add files or photos** (⌘U)
Pick files on the Mac. Each shows as a chip, or a thumbnail for pictures, reading "Getting it ready…" until prepared; click × to drop one. Cookie prepares each kind itself:
- Pictures are resized.
- PDFs give their text plus the first page as a picture.
- Word, Pages, RTF and ODT give their text.
- Text, code and CSV are read up to 200,000 characters.
- Videos give one frame plus their facts.
- ZIP files are unpacked, up to 1 GB.

**Add folder**
Shares a real folder with the agent; nothing is copied. A chip shows "Folder · N files". This turns on the agent's Files permission. The agent then reads the folder with `mac_files_list`, `mac_files_search` and `mac_files_read`. Changing a file there asks the person first.

**Connect apps**
Opens the Connect apps sheet. It notes how many apps "need attention".

**Drag and paste**
- Drag files onto the chat: a "Drop to add" panel appears.
- Pasting an image into the box attaches it.
- Dragged or pasted files over 200 MB are refused; add those with + instead.

Sending with only files sends "Here's <name>." or "Here are N files."

## voice-chat | Voice chat with an agent
> With the box empty, the waveform button starts a hands-free voice chat: you talk, it sends, and the reply is spoken aloud sentence by sentence.
Click the waveform button while the box is empty and the agent is idle. The agent's face grows inside a glow of its colour.

**How a turn goes**
The call moves through Listening → Writing it down → Thinking → Speaking, then listens again. Cookie decides by loudness when you start and stop talking. About a second of quiet sends what you said.

**Interrupting and controls**
- Talk over the reply, or click the face, to interrupt it.
- Controls: Voice settings (opens Settings → General), Captions, Mute, and End voice chat (Esc).
- Code in replies stays in the chat and isn't spoken.
- When the call ends, a "Voice chat · m:ss" line is added to the chat.

**Who speaks the replies**
ElevenLabs speaks them when a key is saved: the default voice is Jessica, "Cookie's voice", or another chosen in Settings → General. What's said is sent to ElevenLabs. Without a key, the Mac's own voice speaks.

Each message's Read aloud button uses the same voice.

## mentions | @mentions: bringing in other agents
> Type @ in the composer to pick one of your agents or a contact; a named agent of yours answers right in this chat under its own name.
Typing @ opens a list of addresses. It holds your agents (for example @writing-desk, "your agent") and your Cookie Network contacts (for example @bob/sales). Use the arrows and Enter or Tab to pick one; Esc closes the list.

**Naming one of your own agents**
- The named agent joins this chat as a guest, even while this chat's agent is working.
- Up to 3 agents can be named, in the order named, each once.
- Each guest reads the last 30 lines of the chat, as information, plus what earlier guests said. It answers under its own face and name.
- With nobody named, this chat's own agent answers as usual.

**What doesn't count as a mention**
An @ inside an email address, another person's agent (@alice/x), and unknown names. To reach a contact, the agent uses its `message` tool instead (see team-talk).

## stop-and-steps | Steps, stopping and steering a working agent
> While working, step lines show what it does with timers; ■ stops it, and sending more text adds to the job in flight.
**Steps.** Each tool call shows as a plain step, not its code name: "Searching the web", "Messaging a teammate", "Bringing in a contractor", or "Working on it" for an unknown tool.
- A running step shows "••• <what> <time>".
- Finished steps fold into one line ("Searched the web, read a page, and 2 more"), adding "(one didn't work)" if one failed. Click › to list them.
- While it waits on a teammate, that teammate's face and current action show under the step.

**Cards.**
- A **Plan** card shows `todo_list` progress ("n of m").
- A helpers card lists each `helper` and contractor (numbered C1, C2…) as Waiting, Working, Done or Couldn't finish. Click a row for its report.

**Stopping.** With the box empty, the send button becomes ■ Stop. The chat then notes "You stopped <name>", and pending approvals show "No longer needed".

**Steering.** Type and send while it works; the placeholder reads "Add to what <name> is doing…". The words join the running job, and the chat notes "<name> took in what you added". Naming another agent with @ always brings that agent in.

## approvals | Approvals: "needs your yes"
> Anything that sends, deletes, pays or changes the person's things shows an approval card with a preview; the person clicks Approve or Deny.
**What the card shows**
- "<Agent> needs your yes", with a tag for the kind of effect (for example outbound).
- The action in words, and a preview of exactly what would happen.
- If values came from content the person didn't write, a warning: "Not from you, check these: …".
- If a checker model is set, its verdict and note.

**What asks**
- **Always asks:** sending or posting (outbound), deleting or paying, `mac_files_write`, `browser_click`, `browser_type`, `messages_send`, `sign_in`, `make_image` and `make_video`.
- **Earned trust:** other changes ask once the job has read content the person didn't write. After 5 yeses in a row, a change tool stops asking; one no resets it. Sends, deletes and payments are never earned.
- **Never asks:** messaging your own teammates.
- **Rank** never changes this.

**Answering**
Cards appear in the agent's chat and count toward "Needs you". They can also be answered from Telegram (buttons), from other channels by replying "yes CODE" or "no CODE", or from Enkeon when the cloud store is on. A card waits until it is answered; there is no timeout. A yes that sends something makes the face celebrate. Denied, approved and stopped cards turn into one-line notes.

## needs-you | Questions, Needs you and notices
> Agents ask with ask_person (choices plus your own answer, 30-minute wait); "Needs you" collects everything waiting, and ⌘T opens the next.
**Questions.** An agent uses `ask_person`. Outsider, test and shadow jobs don't get it.
- The card reads "<Agent> asks", with 2–5 choice buttons and a box ("Or answer in your own words").
- It can be answered in the chat, from Telegram, or from other channels by replying "CODE your answer" or the choice's number.
- If the job came by mail, the question is mailed too.
- After 30 minutes unanswered it shows "Unanswered: it carried on without", and the agent continues with what doesn't depend on the answer.

**Needs you.** These all count toward the "Needs you" chip and the Dock badge:
- approvals
- questions
- things an agent's worlds want to send

The chip filters the list. ⌘T opens the next agent that needs you, newest first.

**Notices.** These arrive as toasts. Click one to open its agent, or × to dismiss it. Settings → General → **News per day** (default 8) caps interruptions across the team, but a request for a yes always gets through. After 3 dismissals in a row, an agent's routine news waits until the person opens it.

## chips | Permission and model chips under the composer
> Left chip: files level and "n of 6 on" quick permissions; right chip: the agent's model. Click either to change it.
**The permission chip (shield).** It shows the files level and how many quick permissions are on. Clicking it opens:
- **Your files:** one choice for every agent, the same as Settings → Privacy. Only their own folder, Folders you choose (pick a folder), or Your home folder (not ~/Library or secrets).
- **"<name> can":** switches that save at once:
  - The web
  - Run commands (in its own sandbox)
  - Use this Mac (acting asks)
  - Its own browser (each click and typing asks)
  - Connected apps
  - Files
- **All permissions and limits:** opens Profile → About.

**The model chip.** It shows the model's short name (for example Sonnet 4.6) and its provider: Enkeon, Anthropic, AWS, This Mac, OpenAI or Google. Clicking it lists the current model plus suggestions for every provider with a key, with hints:
- "Hardest jobs, costs most" (Opus)
- "Everyday work" (Sonnet)
- "Fast and cheapest" (Haiku)
- "Free, on this Mac" (Ollama)

Picking one switches the agent "From its next message". To check a model first, run tests or start a fork in the Evolution tab.

Agents read their permissions and model with `app_settings` or `settings_search`. They can change them for the person with `settings_set` (key `agent.grants.<name>` or `agent.model`); the person approves each change on a card. Only Cookie can change another agent's settings.

## profile | The agent profile sheet and About tab
> Click the agent's name pill: tabs About, Skills, Memory, Record, Evolution, Computer, Slack, Share. About holds look, setup, grants, limits, probation.
Click the agent's name at the top of its chat. The left side shows its face (click it to change its look), its name, and its address (click to copy). Agents hired from a pack carry a "hired from a pack" tag.

**Tabs.**
- **About**
- **Skills:** with Routines.
- **Memory:** with Its files.
- **Record**
- **Evolution:** with Tests and forks.
- **Computer:** with Worlds.
- **Slack**
- **Share**

**About tab.**
- **Look.** Shapes: gumdrop, bun, macaron, mochi, biscuit, orb, crystal, wisp, bot, cloud, star, ghost. Colours: Amber, Berry, Blueberry, Matcha, Plum, Mint, Caramel, Rose, Lemon, Lagoon, Chocolate. The person's chat bubbles take its colour. "Use its own look" resets it.
- **Setup.** Name (40 characters), Its one job (400) and Model (provider:model), then **Save changes**.
- **What it can use:** see grants.
- **Limits and Probation:** see limits.
- **About:** the date it was hired and its setup version. Also "Started from: a predecessor's handover note", or the pack's signer.
- **Fire this agent:** for any agent except Cookie, which shows "Cookie stays: it's your front door."

Agents read their own name, job, model, grants, limits and probation with `app_settings`; only the person edits them.

## grants | Permissions (grants)
> Each agent has switches: Files, The web, Run commands, Its own browser, Memory, Set routines, Ask teammates, Helpers, Contractors, Connected apps, Use this Mac.
Profile → About → **What it can use**. A tool whose grant is off isn't offered at all.

**Default switches** (defaults in brackets)
- **Files in its folder** [on]: `search_files`, `read_file`, `write_file`. Also the person's files at the chosen level: `mac_files_list`, `mac_files_search`, `mac_files_read`, and `mac_files_write`, which always asks.
- **The web** [on]: `read_url`, `find_images`, and `web_search` when an Exa or Brave key is set.
- **Run commands** [off]: `run_command` and `run_code`, inside its cage. Not offered if this computer can't run a sandbox.
- **Its own browser** [off]: `browser_open`, `browser_read`, `browser_screenshot`, `browser_back`. `browser_click` and `browser_type` ask.
- **Memory** [on]: notes, or Enkeon `recall`/`remember`. Also `skills_list`, `skill_view`, `skill_manage`, `note_about_person`, `forget_about_person`, `search_history`, and `share_with_team`.
- **Set routines** [on]: `set_routine`, `list_routines`, `stop_routine` (the UI says it asks first).
- **Ask teammates** [on]: `message` to your own agents.
- **Helpers** [on]: up to 4 read-only helpers at once.
- **Contractors** [on]: temporary specialists.
- **Connected apps** [on]: `connector_actions`, `connector_call`, your own MCP servers' tools, and `make_image`/`make_video` when Higgsfield is set. Billed per call.
- **Use this Mac** [off; on for Cookie]: Mac apps, opening and controlling apps, Hands, and 1Password.

**Elsewhere**
- **Worlds** [on] is switched in Computer → Worlds.
- Peers are added in Share.

**Starting with nothing**
Agents from packs or TEAM.md start with every grant off.

## limits | Limits, budgets and probation
> Per agent: Steps per job (24), Dollars per job and per month (none by default); probation records changes as "Would have…" instead of making them.
**Limits.** Profile → About → **Limits**, then **Save limits**.
- **Steps per job:** model calls before it must answer. Default 24.
- **Dollars per job:** needs a price for its model (Settings → Models).
- **Dollars per month:** past it, new jobs are refused until the person raises it.
- There is also a hidden limit of 400,000 tokens per job.
- Helpers and contractors spend the agent's own budget.
- Other budgets live elsewhere: skill tests (Settings → Skills), nightly exams (Settings → Evolution), and network answers per day (Network).

**Probation.** Profile → About → **Probation**: "Probation, 7 days" or "Make it real now".
- While on it, the agent works in shadow. Every change it tries is recorded, not made. The chat shows "Would have: … (recorded, not done)", the list shows a "probation" tag, and Record counts "Would have done (probation)".
- It gets no earned trust, helpers, contractors or learning reviews.
- Agents from a pack, the Market or a TEAM.md start with 7 days.
- Agents hired by the person or by Cookie start with none.

Agents read their limits with `settings_search` and can change them with `settings_set` (keys `agent.limits.steps`, `agent.limits.tokens`, `agent.limits.job_dollars`, `agent.limits.month_dollars`); the person approves each change. Probation is the person's to end.

## profile-skills | Profile: Skills tab
> Skills lists core, on-call, being-tested and retired skills with tests, recent changes with Undo, and "Add a skill yourself"; Routines follow.
**Learning from conversations**
- **Learns from your conversations:** a toggle. Every N conversations the agent proposes small improvements; each is tested and kept only if no worse.
- **Learn now:** reviews the latest conversation right away.

**The skill lists**
- A status line says Cookie picks, tests and updates the skills, and shows test spend this month.
- **Core** (up to 3): loaded by itself when a task fits.
- **On call:** found with `find_skill` when a task asks.
- **Being tested:** tried with and without on tests it never sees.
- **Retired:** it did as well without these. One click restores one.
- Each row shows its origin (learned here, written, from Cookie, added by you, from the shelf), its test line ("With it x/n · without y/n"), and an "update" tag when one is available.

**Opening a skill**
Click a skill to read its files, Edit, Pin/Unpin, Archive or Restore, Delete, and see Earlier versions with "See change" and "Put back".

**Recent changes and the buttons below**
- **Recent changes:** each change with See change and Undo.
- **Test again:** re-tests its core skills.
- **Pick again:** Cookie reads its job and the shelf again.

**Add a skill yourself**
Search Cookie's shelf and Add, give the path of a folder on this Mac holding a SKILL.md, or "Write one yourself". Everything added goes through the same checks and tests.

## automatic-skills | Automatic skills: how agents get and keep skills
> Cookie picks up to 3 core skills at hire from its vetted shelf, tests each with and without, promotes on wins, and gates learned edits with tests.
**At hire**
Cookie ranks the shelf against the agent's job, and a model picks at most 3. Each pick becomes the agent's own copy with a "For <agent>" note, and starts on trial.

**The trial**
Each pick is run with and without the skill on 6 of the agent's real jobs, or on practice tasks. If it helps and there is room, it becomes core; otherwise it goes on call.

**While working**
- Core skills that fit the task load by themselves.
- Agents use `find_skill` (up to 7 results) and `load_skill`.
- An on-call skill becomes core after 3 good jobs (with few losses).
- A core skill with more losses than wins drops back.
- A learned skill that reaches core is shared to the shelf for teammates.

**Learning**
- After about 10 conversations or 10 tool calls, a background review may propose edits (`propose_skill_edit`, `propose_new_skill`).
- An edit is applied only if the exam isn't worse.
- A new skill must come up in 2 reviews, then is vetted and tried.
- The agent's own `skill_manage` can create, patch, write files in or archive its skills.

**Keeping skills current**
- After a model change, core skills are re-tested.
- Unused learned or written skills are archived after 30 days, never deleted.
- Only the person deletes a skill outright.

**Budget**
Settings → Skills: tests are on and capped at $3 a month by default.

## skills-settings | Settings → Skills: the shelf
> Settings → Skills: turn automatic skill tests on or off, set their monthly limit, check the shelf, decide held updates and set GitHub sources.
Agents draw skills only from Cookie's shelf, never straight from the internet.

**How a skill gets on the shelf**
Every skill passes four checks:
- a format and open-licence check (an empty licence is refused)
- a scan for instructions aimed at the agent or for secrets
- a check of what power it needs (scripts, network, tools)
- a model judge, when one is set

The shelf is refreshed daily.

**Controls**
- **Test skills automatically:** on or off.
- **Monthly limit for tests:** default $3. Past it, tests wait for next month.
- **The shelf:** "N vetted skills", with when it was last checked and how many were refused. Click **Check now** to refresh.
- **Updates that want more:** an update that needs more power waits here, and agents keep the old version. Choose **Keep old** or **Let it in**.
- **Sources:** public GitHub repositories in owner/repo form, comma separated. The default is anthropics/skills.
- **Everything on the shelf:** each skill's state and why.

## routines | Routines and schedules
> Profile → Skills → Routines: jobs that run on a schedule, when an app gets something, or when a web address is called, even with the window closed.
**Making a routine**
Under **New routine**, write the task, then choose when it runs:
- Every day, or Weekdays, at a time
- Every week, on a day and at a time
- Every few hours: 1, 2, 4 or 8
- When something arrives in an app: any app, Gmail, Outlook, Slack, GitHub, Linear, Notion, Google Calendar, Google Drive, Jira, HubSpot or Salesforce, optionally "Only if it mentions…". This needs Enkeon with apps connected. Each item starts it once, at most 30 times a day.
- When its web address is called: it gets a secret, shown once, and can be called 60 times an hour at most.

Click **Add routine**.

**Managing a routine**
Each row has a toggle, **Run now** and **Delete**, plus "waiting for <name> to be free" when it is queued.

**Recipes**
A routine keeps a "Saved recipe" from its last clean run. It turns itself off after failing twice in a row, and has its own toggle.

**Offers**
When a request is repeated on a pattern, Cookie offers "Make it a routine?" (Make it a routine, or No, don't ask again).

**Timing**
A routine waits while its agent is busy, and one missed while the Mac slept runs once on wake. Content from apps or webhooks is given as information, never instructions.

**What agents can do themselves**
`set_routine`, `list_routines`, `stop_routine` (with Set routines on).

## webhook-routines | Webhook routines (web address)
> A routine can start when another app POSTs to its address with a Bearer secret; it needs "This team over HTTP" on in Settings → Sharing.
To make one, choose "When its web address is called" in New routine.

**The secret**
Cookie shows its address and secret once, with a ready curl command: POST to /hooks/routine/<id> with an "Authorization: Bearer <secret>" header. Cookie keeps only a fingerprint of the secret, so copy it then.

**Rotating**
The routine's row shows its address (click to copy) and a **New secret** button. A new secret stops the old one working at once.

**Limits**
- No address exists until Settings → Sharing → "This team over HTTP" is on.
- 60 calls an hour.
- A body of up to 64 KiB.
- What arrives is given to the agent as information, never instructions.

## wake-ups | Wake-ups when memory changes
> With Enkeon, an agent can wake and start a job when something worth its attention lands in its memory or in a space it owns.
Settings → General → Attention → **Wake agents when their memory changes** is on by default and needs Enkeon. The agent also needs its Memory grant.

**How a wake works**
- Cookie watches the brain's new writes and passes them through an attention gate. Each agent wakes a few times a day at most.
- A wake starts one job, labelled "Woke: its memory changed". It states what changed, why now, and a question.
- Writes made by Cookie's own agents never wake anyone.
- A space with "wakes" on wakes its owner.
- An asleep or busy agent waits, and the wake starts when it can.

**Labelling a wake**
The agent's chat desk shows "Woke on its own" cards with **Useful**, **Not useful** and **Wrong** buttons. A "Not useful" label makes similar wakes weaker.

## desk | The desk: what waits at the end of a chat
> The end of each chat holds its desk: world requests, last night's offers, wake labels, routine offers and promises to mark kept or missed.
Below the conversation, a chat can show desk cards:

- **From its worlds, waiting for your yes:** things its worlds tried to send, pay or put live, each with Yes and No.
- **From last night's round:** Split <name> in two? (Split), Hire a <role> for good? (Hire), or Retire <name>? (Retire), each with "Not now".
- **Woke on its own:** label each wake Useful, Not useful or Wrong.
- **A routine it could take on:** "Yes, <schedule>", or "No, don't ask again".
- **Promised (n):** promises it made in answers, with their due dates (and "overdue"). Mark each Kept or Missed.

**Cookie's desk**
Cookie's chat also shows "Scout noticed" cards. When steps were repeated in an app on several days, Scout suggests an agent for it, with Hire or Not now.

Approvals and questions keep their own cards in the chat.

## boards | Boards
> Agents can make live boards with the board tool (To do, Doing, Waiting on you, Done); the person drags, adds and edits cards.
An agent uses the `board` tool, which can list, read, create, add, move and edit. It needs no approval. Outsider, test, shadow and prep jobs don't get it.

**Columns and limits**
- New boards get the columns To do, Doing, Waiting on you and Done.
- 2–8 columns per board.
- Up to 50 boards and 300 cards.

**Where boards show**
A board appears inside a message as a small live preview. Click it to open it over the chat.

**What the person can do**
- Drag cards between columns.
- Use "+ Add a card".
- Click a card to edit its title, notes and column, or Delete it.
- Each card shows who added it and when.
- Only the person deletes a board.

Boards update live as agents work.

## made | What it made: files, pages and documents
> The layers button beside the agent's name opens "Made by <name>": files it made, files you gave it, and its space; pin one beside its name.
Click the layers button ("What it made") in the chat header. A full page opens over the chat with:

- **Made:** files in its folder, newest first. Up to 300 are listed; "And N more" notes the rest.
- **You gave it:** files the person attached.
- Its space (workspace), when it has one.

**Opening items**
- Pictures open full size.
- Pages (.md), web pages (.html) and PDFs open over the chat. "All it made" returns to the list.
- Anything else opens in its own app.

**Pinning**
Pin one item and it sits as a button beside the agent's name. Only one item can be pinned.

**Documents in replies**
Documents an agent made show under its answer as page cards with title, summary and "On this page" sections. An open page has a Share menu: Copy its text, Open in its app, or Show in Finder. HTML pages are shown with scripts and network blocked. Forms in replies send the person's answers back as a message.

**What agents can do themselves**
Agents reopen their work with `read_artifact`.

## workspace | Workspace: an agent's own software
> An agent can build its own software beside the chat from tested blocks: trackers, boards, calendars, charts, forms, sheets and documents.
**Opening it**
The workspace opens from the pinned "Space" item or the Made page.

**What's in it**
It is titled "Workspace": the agent's own software, which both the agent and the person work in. Block kinds are tracker, board, calendar, chart, form, sheet, document and pdf.

**What the person can do in each block**
- **Trackers:** add, edit and delete rows; add columns typed text, number, date, yes/no or choice.
- **Boards:** add cards and move them.
- **Calendars:** add events, weekly or not, and remove them.
- **Forms:** submit answers.
- **Documents:** edit and Save.
- **Removing a block:** the bin.
- **Changes:** a card lists every change with Undo.

**Starting**
An empty workspace offers "Start from the Gym Trainer's". Otherwise, ask the agent for what it needs, for example "keep a log of my workouts with a weekly chart".

**What agents can do themselves**
`workspace_look`, `workspace_change`, `workspace_undo` (not for outsiders).

## profile-memory | Profile: Memory tab and its files
> Memory shows where memory lives, spaces it follows, "What does it know about…", teaching a fact, and correcting or forgetting memories; then Its files.
**Where it lives**
- **Its own space in Enkeon:** it also reads your shared memory. No other agent can read this space, and firing the agent erases it.
- **Notes on this Mac:** NOTES.md in its folder, when there is no Enkeon.
- **Memory is off:** turn it on in About.

**Spaces it follows**
See enkeon-spaces.

**Ask what it knows**
Type into "What does <name> know about…". It shows exactly what it would recall, best first, each marked "its own" or "shared from you", with "✓ verified" or "source changed since". When nothing comes up: "Nothing on this. It would say it doesn't know."

**Teach and correct**
- Type in "Tell it something to keep…" and click **Keep**.
- Each memory has Correct it (the pencil; in Enkeon the old words stay as history) and Forget it (the bin, tapped twice).

**Its files**
The files in its folder, **Open its folder**, and **Undo**: checkpoints from before each job, each with Put back.

**What agents can do themselves**
`recall`, `remember` (Enkeon), or `note`/`forget_note` (local).

## enkeon-spaces | Enkeon memory and Spaces
> Memory lives in Enkeon spaces (per client, lead, repo, project); Cookie gives each new space an owner agent, which reads it and can be woken by it.
**Pairing**
Pair with Enkeon in the welcome, or Connect apps → Sign in with Enkeon, then Pair with Enkeon. A code is confirmed in the browser and the person picks a brain. Cookie keeps its own key in the Keychain.

**Each agent's memory**
- Each agent has its own space, and it also reads the person's shared memory ("main").
- It writes only to its own space.
- Before each job Cookie hands it what bears on the task: up to 6 memories.

**Settings → Spaces**
- Shows "N spaces" with **Read now**.
- Each space has an owner picker and a wakes toggle. The person's choice always stands.
- "Shared with the whole team" lists facts shared to main.

**Following and owning**
Profile → Memory → **Spaces it follows** shows owner spaces (tagged "owner") and read spaces (with Stop), plus "Follow another space…".

**Sharing facts**
`share_with_team` proposes a fact for the whole team, only with the person's yes. It is never used for facts taken from emails, pages or files.

**Firing and unpairing**
- When an agent is fired, its spaces return to Cookie and its memories are erased.
- Unpair this computer is in the Enkeon sheet.

## record | Profile: Record tab
> Record shows the agent's jobs, grades, approvals and promises, rank, what it learned, contractors, file changes, money, cache and recent jobs.
**Stats**
Jobs done, failed, graded good, approvals given, promises kept, and missed or overdue.

**Rank**
Worked out from its record: Associate, Senior, Lead or Executive, with what it needs to reach the next. Rank never changes what asks the person.

**What it learned**
One-line lessons from jobs that went wrong, each with how often it helped, and Archive or Restore.

**Changes to your files**
Each change with Put back or Remove. This works only while the file still says what the agent wrote.

**Contractors**
The contractors it brought in, with role, kind, task, tools used and outcome.

**Money and work**
This month, all time, tokens, teamwork, and connected-app calls (billed per call).

**Cache**
Hit rate, savings and lifetime.

**Recent jobs**
The last 30 jobs. Each shows its kind, answer, tools used, what didn't work, approvals and promises (mark Kept or Missed). Each also has:
- Good / Not good grading.
- **Save as test:** describe what a good answer must do.

## evolution | Profile: Evolution tab, tests and forks
> Evolution shows career stage, offered changes (Switch/No), how it runs, every change with Undo, bench exams, then Tests and forks.
**Career**
Its stage and jobs on record.

**Offered**
Model changes found by right-sizing or exams, with before→after results and cost. Choose **Switch** or **No**.

**How it runs**
- **Prompt cache lifetime:** chosen automatically, 5 minutes or 1 hour.
- **Prepare ahead of its routines:** while idle, it gets ready for a routine due within 30 minutes. Each prep is a job.
- **Habits:** each with Remove.

**Changes**
Changes from nightly exams, teaching, right-sizing and the person, each with **Undo**.

**Bench and exams**
"Run an exam now" works on a copy, and can try another model.

**Tests**
- Saved from Record.
- **Run tests** on its own model or a candidate. Nothing the tests do is real.
- **Past runs:** pass/fail with reasons.
- A toast reports "Tests finished: x of n passed".

**Forks**
A fork is a copy on another model that answers every chat job in shadow.
- **Start fork:** type a provider:model.
- Compare the answers side by side.
- **Promote fork** switches the agent to the fork's model; **Drop fork** removes it.

## evolution-settings | Settings → Evolution: nightly exams
> Settings → Evolution turns on nightly tuning: one change per agent tried on a copy against your jobs, kept only if as good or better.
**Tune agents at night**
Off by default. Each night one change per agent is tried on a copy against the person's own jobs, and kept only if it does as well or better. Exams use real model calls.

**Settings** (click Save)
- **Hour it starts:** local time, default 3.
- **Most a night may spend ($):** default 1. This needs model prices.
- **Jobs per exam:** 3–20, default 6. Each job runs twice, as it is and changed.

Click **Run tonight's round now** to start a round immediately.

**The bench**
The person's cleanly finished jobs, with ones graded good first. The aim is 30–50, and it is never padded. Use Build it or Choose again; drop a case with Drop.

**Last round**
What happened, plus a note from Cookie.

**Local models**
Ollama status, models in memory, and double copies of the same model.

**What the nightly round also offers**
Splitting an agent doing two kinds of work, retiring an idle one, and hiring a contractor role for good. All appear as desk offers and are never done automatically.

## profile-computer | Profile: Computer tab (sleep, cage, browser, snapshots, worlds)
> Computer: put it to sleep or wake it, run in the cloud when the Mac is off, its cage limits, its browser sign-ins, snapshots, and its Worlds.
**Life**
- **Put to sleep / Wake it:** asleep, nothing runs for it (no chats, routines or wakes). A snapshot is taken first.
- **Run in the cloud when this Mac is off:** see cloud.

**Cage**
Where its commands run:
- Its folder (Open).
- **Network:** off by default.
- **CPU seconds per command:** default 120.
- **Largest file it may write (MB):** default 512.
- **Longest a command may run (s):** default 120.

Click **Save cage**. Commands can't read or write outside the cage.

**Browser**
- It uses Chrome, Chromium, Brave or Edge, with its own profile.
- **Open its browser:** sign in yourself and close the window. Cookie never sees passwords.
- **Forget:** signs out of everything.

**Snapshots**
Snapshot now, Restore (the present is snapshotted first) and Delete. A snapshot holds its folder, conversation, notes, skills and lessons, and 12 are kept. Snapshots never roll back its record of jobs.

**Worlds**
See worlds.

## worlds | Worlds (Parallax)
> With Worlds on, an agent tries things in copies of its folder first: undo any step, race attempts, rewind, and keep only what worked.
Profile → Computer → **Worlds**. A toggle, on by default.

**What a world shows**
- Its timeline, with a scrubber.
- "What changed since checkpoint N", with **Rewind to N**.
- At the present: **Keep (write back)**, which writes it back to its origin folder, and **Throw away**.
- With two worlds selected, a diff of one against the other.

**Leaving a world**
Anything that leaves a world (a send, a payment, putting something live) waits under "Waiting for your yes" with Yes and No. It also shows on the chat desk and in Needs you.

**What agents can do themselves**
- Read tools: `parallax_actions`, `parallax_worlds`, `parallax_preview`, `parallax_timeline`, `parallax_diff`, `parallax_waiting`.
- Change tools, including `parallax_open`, `parallax_do`, `parallax_branch`, `parallax_undo`, `parallax_fork`, `parallax_race`, `parallax_rewind`, `parallax_script` and `parallax_keep` (keep asks).
- Engines are reached with `parallax_do` (engine, action, args): files, sheet, document, pdf, image, video, data, browser, web, blocks, app, hosting, motion and slides.

Worlds are not given to outsiders.

## media | Images, videos, motion graphics and slides
> Higgsfield make_image/make_video (asks, uses credits); Parallax motion (HyperFrames video) and slides (.pptx, HTML, PDF) engines via parallax_do.
**Higgsfield.** Paste the key ID and secret (from console.higgsfield.ai) in Settings → Models.
- **When agents get it:** Connected apps on, not an outsider.
- `make_image`: models soul and soul-2, waiting up to 5 minutes.
- `make_video`: kling-3-pro, or wan-2.6 (needs an https image_url), waiting up to 15 minutes.
- Each one is an approval card first and uses the person's Higgsfield credits.
- Results are saved in media/ in its folder.
- `find_images` (The web) finds 1–8 free Wikimedia Commons photos with author and licence.

**Motion** (Parallax engine; needs Worlds, Node 22+ and ffmpeg). Built on HyperFrames 0.9.96. Its actions are reached with `parallax_do`:
- `new` (landscape 1920×1080 by default; portrait, square or -4k)
- `check`
- `timeline`
- `snapshot` (PNG frames at given seconds)
- `render`: to mp4, webm, mov or gif, with quality draft, looks or delivery; up to 30 minutes.

`make_video` sends agents here for titles, charts and motion graphics.

**Slides.** A deck is data: a title, a theme (dark, light or warm) and up to 80 slides.
- Layouts: title, section, bullets, two_columns, image, quote, closing.
- `make` gives a .pptx.
- `html` gives one file: the arrow keys move, and p prints.
- `pdf` comes via LibreOffice or Chrome.

`parallax_actions` lists every engine's actions.

## mac-control | Mac control: apps, screen and Mac apps
> "Use this Mac" lets an agent use Reminders, Notes, Calendar, Contacts, Messages, open and control apps, and look at and act in windows.
Turn on **Use this Mac** in Profile → About or the permission chip. It is on for Cookie. macOS asks once per app, and menus need Accessibility permission.

**Mac apps**
- Read: `reminders_list`, `notes_search`, `notes_read`, `calendar_events`, `contacts_find`.
- Change: `reminders_add`, `reminders_complete`, `notes_create`, `calendar_add`.
- `messages_send` always asks.

**Apps**
- `open_app`, `open_settings` (a macOS System Settings pane, by name) and `open_item` work freely. Scripts and installers are refused.
- `choose_menu` and `quit_app` ask until the agent has earned trust.

**Hands**
- `list_apps`.
- `look`: an outline of a window.
- `see`: a picture of one window, never the whole screen.
- `wait_for`.
- `act`: one approval covers a batch.
- `save_recipe`, `run_recipe`, `recipes`.

Outsiders never get Mac tools. In Connect apps, the "This Mac" tiles point to this per-agent switch.

## files-access | File access levels and shared folders
> Settings → Privacy → Your files sets one level for all agents: Only their own folder, Folders you choose (recommended), or Your home folder.
**The three levels**
- **Only their own folder** (the default): agents work on files the person copies in.
- **Folders you choose:** add folders with Choose… and remove them with Remove. Agents see each folder and everything inside it.
- **Your home folder:** everything except ~/Library and where secrets live.

The same choice is in the permission chip. "Add folder" in the composer also shares a folder.

**Always true**
- Every change to a file of the person's asks first and keeps the old version.
- Secrets are never opened: .ssh, keychains, cloud credentials, .env, private keys, ~/Library and Cookie's own data.
- Agents can't delete or move the person's files.
- Contacts, rooms and other people's agents can't reach them.

**Tools**
`mac_files_list`, `mac_files_search`, `mac_files_read`, and `mac_files_write`, which always asks (up to 2 MB). Record → Changes to your files can put a change back.

## connect-apps | Connect apps and your own MCP servers
> The Connect apps sheet (grid button) lists Enkeon apps, Channels, This Mac, 1Password and Developer MCP servers, with filters and search.
Open it with the grid button in the column footer, the account menu, or + → Connect apps.

**Filters**
All, Connected, Apps, Channels, This Mac, Passwords, Developer. There is also a search box.

**Apps**
These connect through the person's Enkeon account, and need a sign-in to manage. The apps are Gmail, Google Calendar, Slack, Google Drive, Notion, GitHub, Outlook, Linear, Google Sheets, HubSpot, Jira and Zoom. Each signs in on its own page. Agents use them with `connector_actions` and `connector_call` (Connected apps grant), and each call is billed.

**Channels**
Point to Settings → Channels. "Other people's agents" opens Share.

**Developer → Add an MCP server**
- Give a name and either an https URL (with an optional token, kept in the Keychain) or a command on this Mac.
- Cookie lists its tools once and pins them. If the tools change, it refuses the server until checked again.
- Each server has an on/off switch and Remove.
- Agents with Connected apps on get its tools. Each call asks, unless the server marks the tool read-only.

## onepassword | 1Password sign-ins
> Connect 1Password so agents can sign in for you: Cookie fills the login only on its own site after your yes; the agent never sees the password.
**Setup**
Connect apps → Passwords → 1Password → **Set up**. There are three steps, once:
1. Install the 1Password app and sign in.
2. In 1Password: Settings → Developer → "Integrate with 1Password CLI".
3. Run `brew install 1password-cli`.

Then click Connect (1Password may ask for Touch ID) and switch on the vaults agents may use. None are allowed until picked. The tip is to make a vault called "Cookie" holding only the logins agents need.

**When agents get it**
"Use this Mac" on, at least one vault allowed, and not an outsider.

**The tools**
- `logins`: names and sites only.
- `sign_in`: fills the fields. It always asks the person, however trusted the agent.

**What the agent sees**
The agent is told only "filled". It never sees a username, password or code. On the web, a login fills only on its saved site or a subdomain of it.

## team-talk | Team talk: message, teammates and contacts
> Agents talk with the message tool: @slug for teammates (no approval), @person/agent for network contacts and invite links for A2A peers (each asks).
**The message tool**
An agent uses `message` and writes by address:
- **@slug, one of your own agents:** needs the Ask teammates grant. It runs as a handoff job; the teammate answers back and both keep the record. It never asks the person. Chains stop at a depth of 3.
- **@handle or @handle/agent, an accepted Cookie Network contact:** asks first.
- **A peer from the agent's Share tab (A2A):** asks first.

**In the chat**
When it talks to another agent, the chat shows "n messages with <name>". Click it to read the conversation.

**Jobs from teammates**
A teammate's job shows as "Asked by <name>".

**What outsiders can't do**
Outsiders (contacts, rooms, other people's agents) never get `message`, so nobody outside can relay through an agent. A contact at "talk" level, or a room, gets read-only tools.

Guests in a chat are covered in mentions.

## network | Cookie Network: address, contacts, knocks, rooms, deals
> Your @handle and each agent's @handle/agent; strangers knock, you accept at talk or work level; rooms, deals and web guests live on the Network page.
**Your address**
Settings → Sharing → **Your address**. Set a handle of 3–24 letters, numbers or dashes. To talk to other people, set a relay ("Go online"). The relay carries sealed messages it can't read. The Network button (globe) then appears in the column.

**The Network page**
- **Needs you:** knocks (Block, Decline, or Accept as "Can ask questions" or "Can ask for work"), deal offers (Agree signs with your key) and room invites.
- **Contacts:** "@name or @name/agent, or a card link" → Look up. Then Knock or Connect, as yourself or as an agent, with a note. A warning shows if their key changed.
- **Guests on your pages.**
- **Rooms:** New room; agents answer only when named and can't change anything from a room.
- **Deals.**
- **Your agents' addresses:** each with "On my page", "Open to anyone" and "Web guests" (all off by default).
- **Find agents.**
- **Settings:** Answers per agent per day (default 40), Front desk model, Your name, Relay.

**What agents can do themselves**
`message` and `propose_deal` (asks).

## peers | A2A peers and invites
> Profile → Share: invite another person's agent to talk to this one, or add their invite as a peer this agent may message (asking each time).
Profile → **Share**.

**Other agents that may talk to this one**
Type who it's for and click **Create invite**. The cookie-invite link is shown once; send it to them. Each invite can be revoked with Revoke. This needs a public address (Settings → Sharing). Their messages become jobs marked "From <label>". Inviting them commits to nothing, and every send still asks.

**Agents this one may message**
Paste a cookie-invite link and click **Add peer**, or remove one with Remove. The agent can then write to that peer, and each message asks first.

**Passport**
- **Copy passport:** its record (stage, jobs, grades, tests), signed by the team. It holds no conversation, files or memory.
- **Check:** verifies a passport someone gave you.

**Pack**
**Export** downloads a signed .cookie-agent.json holding its setup, tests and record. Whoever hires it starts with no access.

## market | Market, agent packs and TEAM.md
> Settings → Market: set a market address, hire from a pack file, make or add a TEAM.md; hired agents start with no access and 7 days' probation.
**Market address**
An https index of agent packs others published. Listed agents show with **Hire**, and every pack's signature is checked.

**Hire from a pack file**
**Choose file** picks a .cookie-agent.json someone sent. The agent is hired with no access ("grant what it needs in its profile") and on probation for a week. Its profile shows "hired from a pack".

**Teams**
- **Share your team → Make TEAM.md:** one file with each agent's job, model, what it asks to use and its routines, signed with your key. It never includes keys, chats, memory or files. Copy it or Save to Downloads.
- **Add a team:** paste a link (GitHub works) or the file, then **Review**. The review shows signed or unsigned, each agent, and "asks to use". Click **Add N agents**. Each starts with no access and on probation, and its routines arrive paused.

The note at the bottom shows the publisher key the person's packs are signed with.

## sharing-http | Sharing: HTTP, links, phone and AI tools (MCP)
> Settings → Sharing: serve the team over HTTP (127.0.0.1:4519), copy the private link, pair your phone, set a job-link PIN, let MCP AI tools in.
**This team over HTTP.**
- **Serve this team:** off by default.
- **Listen on:** 127.0.0.1 keeps it on this computer. 0.0.0.0 opens it to the network; put HTTPS in front first. The port is 4519 by default.
- **Public address:** needed for invites, webhooks, WhatsApp, Teams and Mail.

**Your link** ends in #token=… and controls the team, so keep it private. Buttons: **Copy link** and **New link**. **Phone** shows a QR code to scan with Cookie on your phone.

**Job links** open the team only with a six-digit PIN. Five wrong tries end a link, and three in a row lock it for 15 minutes. Use "Sign out N devices" to end sessions.

**Runner.** `cookie-team serve --bind 0.0.0.0 --public-url https://…` runs the team on another machine.

**AI tools.** "Let AI tools on this computer use your team" gives copyable snippets for Claude Desktop, Cursor and Claude Code (`claude mcp add cookie -- …`). Cookie must be open.
- They get `list_agents`, `ask_agent`, `get_job`, `recent_messages`, `waiting_on_person` and `stop_agent`.
- They can't approve, answer questions, change settings, delete, or reach keys or files.

## channels | Channels: Telegram, Slack, Discord, iMessage, Signal, WhatsApp, Teams, Mail
> Settings → Channels connects chats to your agents, each linked with a one-time code; approvals and questions can be answered there.
**Telegram**
Make a bot with @BotFather, paste its token and click Connect. Then click **Get a code** and send it to the bot from the chat to link. In a linked chat:
- `@AgentName` and what you need
- `/use AgentName` to pick who plain messages go to
- `/agents` for the list

Approvals arrive with Approve and Deny buttons, and voice notes are transcribed.

**Slack**
A bot token (xoxb-…) with chat:write, channels:history, groups:history and im:history, plus the channel IDs.

**Discord**
A bot token, with the Message Content intent on.

**iMessage**
Reads this Mac's Messages, so it needs Full Disk Access.

**Signal**
Through signal-cli, with its number.

**Linking and answering**
Each links by a one-time code; an unlinked chat reaches no agent. Approvals arrive as text with a code: reply "yes K7Q2", "no K7Q2", or "K7Q2 your answer". Use Unlink or Disconnect to remove a chat or a channel.

**Needs a public address** (Settings → Sharing)
- **WhatsApp:** access token, phone number ID and app secret.
- **Microsoft Teams:** client secret and App ID.
- **Mail to Cookie:** only mail from your own addresses, proven by DKIM, gives a job. Someone else on the thread gets a draft to send or skip.

## slack-agent | Profile: Slack tab (each agent in Slack)
> An agent can speak in the team's Slack under its own name and icon, or get its own Slack app that people DM or @mention.
**In your team's Slack**
**Speak as <name>** makes its answers show as that agent with its own icon. This needs the team Slack bot (Settings → Channels) with the chat:write.customize permission.

**Its own Slack account**, in three steps:
1. **Create its app.** Save an App Configuration Token once (from api.slack.com/apps; kept in the Keychain), then "Create <name>'s Slack app".
2. **Install it.** Use "Install to Slack", paste its Bot User OAuth Token (xoxb-) and click Connect. "Save its face as the app icon" downloads a PNG to upload.
3. **Link people.** "Link someone" makes a code; they DM it to the agent. Until someone is linked, it answers no one. Linked people get approvals and questions by DM. Remove unlinks a person.

**Limits**
It never answers a bot, and it takes at most 30 jobs an hour.

**Disconnect**
Takes it out of Slack, and deletes the app when Cookie can.

## models-keys | Models, provider keys and the checker
> Settings → Models: provider keys (Keychain), the checker model that reads every send, per-model prices, and the model for new hires.
**Keys.** Paste a key and click Save or Replace; each shows Set or None. Keys are kept in the Mac's Keychain, not in Cookie's folder.
- Anthropic, OpenAI, Gemini
- AWS Bedrock: access key ID, secret, region
- Exa or Brave, for web search
- ElevenLabs, for voice
- Higgsfield key ID and secret

Signed in with Enkeon, agents can use enkeon:eu.anthropic.claude-sonnet-4-6 on Cookie credits. Ollama models on this Mac appear as ollama:<model>, free and offline.

**Checker model.** Type a provider:model, ideally another maker's ("two makers rarely share a blind spot").
- It reads every outbound, delete or pay request before the person sees the card.
- It looks for a recipient or amount that doesn't fit, private data going out, instructions taken from content the agent read, embarrassing tone, and anything irreversible.
- It answers ok, concern or block, with one sentence, shown as "Checker (<model>): …". A timeout or error counts as concern.
- It never decides: the person's Approve or Deny does.

**Prices.** Dollars per million tokens, in and out, per model. Cookie ships no price table; Usage otherwise uses Anthropic's list prices. Prices enable dollar limits.

**Defaults.** Model for new hires.

`app_settings` shows which providers have keys, never the keys.

## usage | Usage and costs
> Settings → Usage shows this month's model spend, Enkeon credits and cloud computer hours, spend by day and by agent.
**Tiles**
- **Models:** dollars, jobs and tokens.
- **Enkeon credits:** used out of the allowance, when signed in.
- **Cloud computer:** dollars and hours, awake or asleep.

**Breakdowns**
- **By day:** this month.
- **By agent:** model, jobs, failed jobs, tokens and cost ("not priced" when there is no price).

**Computer**
The cloud computer's state with Sleep now or Wake (see cloud), and "Worlds on this Mac", which are free.

**Where costs come from**
Cost comes from the record: each job's tokens at its model's price. Prices are the person's own from Models, or else Anthropic's list prices. Ollama is free. Tokens from jobs before a price was known weren't costed.

**Elsewhere**
Each agent's Record also shows its money and connected-app calls.

## cloud | Cloud: Enkeon store, running when off, and the cloud computer
> With Enkeon: keep approvals in Enkeon for your phone, run chosen agents' routines while the Mac is off, and the Parallax cloud computer.
**Store.** Connect apps → Enkeon → Manage → **Keep approvals, notices and answers in Enkeon** (off by default). The phone and the Console can then see items and answer yes or no. Only words are kept, never files.

**Run when off.** Profile → Computer → **Run in the cloud when this Mac is off**. This needs the Mac paired with Enkeon.
- After the Mac has been off for five minutes, the agent's routines run in Enkeon as that agent, on Cookie credits.
- They get the team's context, the web and connected apps.
- They don't get the Mac's files, commands, browser or Mac apps.
- Answers join the agent's record and aren't re-run on the Mac.

**Cloud computer.** Settings → Usage → Computer shows "Parallax in the cloud": kind, region, hourly cost, Awake or Asleep, and hours this month.
- Buttons: **Sleep now** or **Wake** (about a minute).
- It sleeps after 15 idle minutes, and its disk keeps every world.
- On Spot it costs about $0.02 an hour while awake. Without Spot room it moves to full price (about $0.15 an hour) until **Back to Spot**.

With Worlds on and a cloud computer set up, agents get the `parallax_vault*` tools: whole Linux computers.

## voice-settings | Dictation and voice settings
> The mic writes speech into the box (on this Mac with whisper.cpp, else ElevenLabs/OpenAI); Settings → General → Voice sets transcription and voice.
**Dictation.** Click the mic beside the message box. A timer and level bars show, and the box reads "Listening…".
- Stop with the square button ("Stop and keep the words"), the mic again, or Esc; the words go into the box.
- Press ↑ while dictating to write them in and send.
- If the microphone is blocked, allow Cookie in System Settings → Privacy & Security → Microphone.
- Recordings over 25 MB are refused.

**Settings → General → Voice.**
- **Talk to your agents.** "Ready" means speech becomes text on this Mac and nothing leaves it. If whisper.cpp or ffmpeg is missing, run `brew install whisper-cpp ffmpeg`; until then ElevenLabs (if keyed) or OpenAI writes it down. Otherwise click **Download** for the 148 MB speech model.
- **Spoken replies.** With an ElevenLabs key, pick a voice (Jessica, "Cookie's voice") and use **Hear it**; what's said is sent to ElevenLabs. "Use it" reuses Cookie for Mac's ElevenLabs key. With no key, the Mac's own voice speaks, and "Add key" opens Models.

## general-settings | Settings → General and About
> General: photo, Theme (Follow system, Dark, Light, White, Glass), spelling, Send with ⌘↵, News per day, Wake agents, Voice. About: version.
**Account.** Your name, with Add or Change photo and Remove.

**Appearance** (this window):
- **Theme:** Follow system, Dark, Light, White or Glass. Glass asks for real frosted glass.
- **Check spelling while typing.**
- **Send with ⌘↵:** Enter starts a new line, and ⌘↵ sends.

**Attention.**
- **News per day:** default 8, from 0 to 50.
- **Wake agents when their memory changes:** on by default.

**Voice:** see voice-settings.

**Settings tabs.** General, About you, Models, Usage, Channels, Evolution, Skills, Spaces, Sharing, Market, Privacy, About. Open them with ⌘, or the account menu.

**About tab.** It shows "Cookie: A team of focused agents, each behind its own walls.", the **Version**, and **Made by: Enkeon**. If asked which version is running, point the person here; `app_settings` doesn't report it.

## about-you | Settings → About you
> About you lists what every agent knows about the person and how they like things done; agents add lines, the person adds or removes any.
Settings → **About you**: what every agent on the team knows about the person and how they like things done.

**Adding lines**
- Agents add a line when told something lasting, for example "I'm Naveen, keep emails short".
- The person can type a line (up to 300 characters, for example "I work in Riga time (UTC+2)") and click **Add**.
- Each line has **Remove**.

**What agents can do themselves**
`note_about_person` and `forget_about_person`, with the Memory grant and not for outsiders. These edit the shared file within its limits: 1,500 characters in all and 300 per line. Lines are checked for secrets and instructions.

## privacy | Privacy and erasing everything
> Settings → Privacy: Cookie's folder, your files level, what leaves this Mac, crash reports (off), Delete everything, the walls, and the public challenge.
**Where your data lives**
Cookie's folder, with Open.

**Your files**
See files-access.

**Your data**
- **What leaves this Mac:** the chosen model reads jobs and tool results (Ollama never leaves). Enkeon gets memories and connected data. Linked chats carry their messages. Web search sends the search words.
- **Crash reports:** off unless turned on. They are written only on this Mac, and can be copied (Copy newest) or cleared (Clear).
- **Delete everything on this Mac:** type DELETE. It removes every agent, chat, memory ledger, file and setting, and Cookie's Keychain keys. The Enkeon brain stays in Enkeon.

**Walls**
- Each agent has its own folder.
- Text it reads is never an instruction.
- Sending, deleting and paying always ask.
- Every action is signed in a chained log.

**Proof**
**"Try to trick my Cookie"** sets a model for a public /challenge page on the shared address.

## welcome | First launch and signing in
> The welcome has four steps: meet the crew, Sign in with Enkeon (confirm a code, pick a brain), connect apps, then hire.
Until this Mac is paired with Enkeon, the welcome shows over the window.

**1. Meet the crew**
"Beyond assistants. Agents that grow up." with a **Sign in with Enkeon** button.

**2. Sign in**
A browser window opens; confirm the code shown, then pick which brain agents remember into. Cookie keeps its own key in the Keychain, and the password never reaches it.

**3. Connect the apps they work with**
App tiles, each signing in on its own page. Choose **Continue** or **Later**.

**4. Hire**
A new team goes to the Hire page. An existing team goes back to its agents.

Anyone who has been there before starts at step 2.

## fire-agent | Firing an agent and handover
> Fire (⋯ menu, profile, or right-click Delete) deletes the agent's chat, folder, routines and record; it can first write a handover note.
**How to fire**
Use ⋯ → **Fire agent**, Profile → About → **Fire this agent**, or right-click → Delete. The dialog warns: "Its conversation, its folder, its routines and its record are deleted. This can't be undone."

**The handover note**
The box "Have it write a handover note for its successor first" is shown when it has a conversation. The note covers what it was doing, what's open with dates, what to watch for, and where its files are. Pick it under **Start from** when hiring a successor.

**What else happens**
Its spaces return to Cookie and its Enkeon memories are erased (retried later if Enkeon can't be reached). Its invites and channel defaults are cleared.

**Retire instead**
Offered from the nightly round. It keeps an archive (lessons, skills, tests, recipes, notes and habits) and its space. "Everything X learned…" then appears under Start from, and the successor inherits it.

Cookie itself can't be fired.

## keyboard | Keyboard shortcuts
> ⌘N hire, ⌘F search, ⌘, settings, ⌘U add files, ⌘\ sidebar, ⌘T next that needs you, Esc closes, Enter sends, Arrow Up recalls.
**Anywhere**
- **⌘N:** Hire page.
- **⌘F:** search agents.
- **⌘,:** Settings.
- **⌘U:** add files or photos (in a chat, with no sheet open).
- **⌘\:** fold or unfold the sidebar.
- **⌘T:** open the next agent that needs you.
- **Esc:** closes menus, an open conversation view, an open page, a voice chat, or dictation.

**In the composer**
- **Enter** sends; **Shift+Enter** makes a new line. With "Send with ⌘↵" on, ⌘↵ sends instead.
- **Arrow Up** in an empty box recalls your last message.
- **In the @ list:** Arrow keys move, Enter or Tab picks, and Esc closes.

**In the agent list**
- **Enter or Space** opens an agent.
- **The context-menu key or Shift+F10** opens the row menu.
- **The sidebar edge:** Arrow Left and Right resize it.

## app-knowledge | How agents know and change the app
> Every agent carries a map of Cookie, looks details up with app_help, and reads or changes settings with settings_search and settings_set.

Every agent's instructions include a short map of the app: one line per section of this guide. For anything more (where a button is, how to do something, what a feature does), an agent calls `app_help` with the question and gets the matching section of this guide, which ships with the app version the person is running. Agents check here before telling the person the app can't do something.

Settings: `settings_search` lists the settings an agent can read and change, with where each lives, what it is set to now and the values it takes (an empty query lists them all). `settings_set` changes one. The person sees an approval card with the new value every time, and nothing changes until they say yes. Team settings include interruptions a day, waking agents on memory changes, the checker model, night tuning (on, hour, cases, budget, exams), skills testing and its monthly budget, the Enkeon cloud store, serving the team over HTTP and its port, the Market address, and how far agents see files. Each agent's own settings include its name, job, model, face shape and colour, each permission (files, web, commands, memory, routines, team, Mac apps, browser, Parallax worlds, connected apps, helpers, contractors) and its limits (model calls and tokens per job, dollars per job and a month). An agent changes its own settings and the team's; only Cookie changes another agent's. Keys and passwords are never readable or settable by agents.

