# The chat app — the design pass

Status: R1-R5 RULED 2026-09-25 (R3: a container role draws the bubble).
The same day the maintainer ruled that role general: a `filled`
container with a closed set of platform tints (docs/tints-plan.md), the
bubble `accent` for the user and `neutral` for the peer. The
goal was named on 2026-09-24 ("let's have the chat app be the ultimate
goal", docs/submit-plan.md §8). Both prerequisites exist: the `submitted`
occurrence (docs/submit-plan.md) and `scroll_to_row`
(docs/scroll-to-plan.md). The task manager (docs/tasks-plan.md) is the
precedent this file follows: what is already true, the v0 surface on
today's kaya, the scene, the rulings, and the sequencing of the features
the app forces. The needs survey's chat row is
docs/probes/roadmap-app-needs-2026-09-05.md §A2.

## §0 — What is already true

- **Why this app.** The survey ranks chat as the archetype where three
  things kaya has only just built all meet: a compose field that sends on
  Return, a list that opens at its newest row and jumps to the first
  unread, and message bodies in right-to-left scripts inside a
  left-to-right shell. It also forces things no earlier app did: a list
  that grows at the bottom while the user reads, rows whose side of the
  screen depends on who sent them, and notifications a user can answer.
- **Synthetic, deterministic data**, as in the task manager and the
  portfolio: a fixed set of conversations and a scripted peer that answers
  from a table.
- **Real traffic over loopback, through the guest language's own network
  stack** (the maintainer, 2026-09-25). The peer is a scripted server the
  app starts inside its own process on `127.0.0.1`, on a port the OS
  picks, so every lane (the phones included) needs no host networking and
  parallel legs never collide. The client reads the socket on its own
  thread and hands each message to the app through `post`
  (`AppCtx::post` / `Poster`), which is the path a real chat app lives on
  and the one this app exists to exercise. Android needs the INTERNET
  permission even for loopback. iOS's App Transport Security governs
  URLSession, not a raw socket. Binding loopback rather than every
  interface should raise no firewall prompt on the mac or Windows; C0
  confirms that rather than assuming it.

## §1 — The surface (v0, on today's kaya)

Everything in v0 exists today. Three screens:

1. **Conversations**: the window's sections, or a list in a list-detail
   window (§4 R2). Each row shows the peer's name, the last message's
   first line as a caption, and an unread count as a badge.
2. **The thread**: a `For` of messages inside a `scroll`. Each message is
   a row whose bubble sits at the leading edge for the peer and the
   trailing edge for the user (a spacer on one side; how the bubble is
   drawn is §4 R3). Messages
   hold rich text with links (docs/rich-text-plan.md).
   `scroll_to_row` carries the thread's navigation, one kind of jump each:
   the thread OPENS at its first unread message (the newest when nothing
   is unread), a row that has never been laid out; a reply's QUOTE jumps
   to the message it quotes, far above the fold in a long thread; a
   search RESULT jumps to its message while the list is filtered; and a
   "jump to newest" button, shown once the user has scrolled up, returns
   to the end.
3. **The compose row**: a `textarea` with `submits` (Return sends,
   Shift+Return inserts a newline on the desktops; the keyboard's Send
   key on the phones) and a Send `button` beside it, which the phones need
   because a hardware keyboard or dictation never shows the Send key
   (docs/submit-plan.md §8).

What the app owns and kaya owns follows the task manager's rule: the
conversations, the unread counts and the peer's script are the app's;
the bubble's alignment, the scroll position and the keyboard are kaya's.

## §2 — The scene (a new `chat` scene, written with C0)

One shared scene, as for every app: open a conversation and read that
its first unread message is in view, type a message and press Return,
read it back as the newest row, wait for the peer's reply off the socket,
tap a quote and read that the quoted message is in view, scroll up and
use the jump-to-newest button, and check the unread count on another
conversation. Each `scroll_to_row` jump is asserted with
`expect_scrolled_to`. Every assertion uses verbs that exist today (`type`,
`press return`, `expect`, `expect_scrolled_to`, `expect_section_badge`,
`select_section`, `expect_no_clipping`, `expect_height_fits` on a bubble
row).

## §3 — What v0 will measure before any new feature

- A `For` inside a `scroll` that grows at the bottom while the view sits
  at the bottom: does each backend keep the newest row in view, or does
  the new row land below the fold? No scene has asked this. It is the
  first thing to measure, because the answer decides whether a
  "stick to the bottom" rule is kaya's (§4 R4).
- A bubble row with a spacer on one side in a right-to-left locale: the
  user's bubble must move to the LEFT edge. `expect_mirrored` reads rows;
  a bubble is a row.
- An Arabic message body inside an English shell: the label's own
  direction comes from its text, not from the window. No backend has been
  asked this yet.

## §4 — Rulings wanted (RECOMMENDED; the maintainer decides)

- **R1 — the language.** Rust wrote the task manager, Go the editor and
  Python the portfolio. RECOMMENDED: **Go**. It is one of the three
  languages that run on all five lanes, and its handler family moved onto
  the handle on 2026-09-24 (docs/deferred.md), which a chat app exercises
  more than any earlier app does. Python is the other candidate. Rust
  would test nothing new.
- **R2 — conversations as sections or as a list-detail.** Sections put
  each conversation in the sidebar, which is how a few chats look in
  Messages on the mac; a list-detail is how Slack, Signal and every phone
  client look, and it scales past a handful. RECOMMENDED: **list-detail**.
  The list's rows then carry the unread badge as a label, since section
  badges belong to sections.
- **R3 — the bubble (RULED 2026-09-25: the container role).** No platform ships a chat bubble: Messages
  on macOS and iOS draws its balloons in the private ChatKit framework,
  Google Messages and Fractal draw their own (Android's "Bubbles" API is
  the floating conversation heads, not this), and WinUI has no such
  control. And kaya refuses per-widget colours, radii and padding
  (docs/styling-plan.md §2), so an app cannot give a row a filled rounded
  background. The three answers: (1) a CONTAINER ROLE, `outgoing` and
  `incoming`, each backend drawing it from its own tokens (the accent
  fill for the user's, a neutral fill for the peer's, the platform's own
  corner radius) — styling-plan D5's "closed to apps, extensible by kaya",
  as the button and label roles are; a spec change on four backends.
  (2) a canvas per bubble, which loses selection, links, accessibility and
  the platform's text layout. (3) no bubble, messages as plain rows on
  alternating sides. RULED: (1), without a tail. An emoji-only message
  takes no role, which is how Messages shows one. STILL OPEN: the
  maintainer asked whether the colour ruling should loosen. The proposal
  on the table is a closed set of TINTS (accent, success, warning,
  critical, neutral), each lowered to the platform's own fill and
  foreground pair so contrast holds in dark and high-contrast modes, on
  a general FILLED CONTAINER role that the bubble uses as accent and
  neutral; raw data colours (a project dot, an avatar) held until a
  consumer asks.
- **R4 MEASURED 2026-09-25: no platform follows the end by itself.** The
  chat scene with the app's own scroll on an arriving reply removed, the
  view sitting at the end after the user's send, and `expect_at_end` read
  1.5s after the peer's reply landed: every lane left the view where it was,
  one row short — mac content bottom 544 against a 500pt viewport, GTK 1646
  against 1698, WinUI 1647 against 1700, iOS 625 against 577, Compose 1000
  of 1048. So by R4 the follow is kaya's: a scroll prop, designed in its
  own pass (C1).
- **R4 — stick to the bottom.** When the user is at the newest message and
  a new one arrives, every chat client keeps the view at the bottom; when
  the user has scrolled up, it does not move them. RECOMMENDED: measure
  first (§3). If any backend does not do this by itself, it becomes a
  scroll prop (`follows_end`) with one meaning on every backend, designed
  in its own pass.
- **R5 — the peer's pace.** The server answers after a short delay
  (200ms). RECOMMENDED: the scene waits on the reply with `expect`'s
  retry and never sleeps.

## §5 — Sequencing (one forced feature per stage)

| stage | builds | forces |
|---|---|---|
| C0 | the app on today's surface: guest, scene, five lanes (BUILT 2026-09-25: guests/go/chat, tools/scenes/chat.steps; the app follows every new message with `scroll_to_row` itself, so §3's "does the platform keep the newest row in view" is still unmeasured and is C1's first step) | a Go record row's `Button` and `Spacer` (the generated façade lacked both) |
| C1 | the thread stays at the bottom as messages arrive, and stays put when the user has scrolled up (BUILT 2026-09-25: `follows_end`, docs/follow-end-plan.md; the app no longer scrolls to an arriving reply itself) | a scroll prop that follows the end (R4 measured: no platform does it by itself) |
| C1b | a compose field that grows from one line as the message does, up to a few lines, then scrolls (BUILT 2026-09-25: `max_lines`, docs/grow-lines-plan.md) | a textarea that sizes to its content between a floor and a cap (SwiftUI's `TextField(axis: .vertical)`, found by C0's first capture: a textarea is several lines tall at rest) |
| C2 | an unread count on the dock and taskbar (BUILT 2026-09-26: the unread total, set when it changes rather than at launch, since on iOS the first set_badge raises the permission prompt and a prompt up before the scene types would take the keyboard; docs/app-badge-plan.md) | the app badge (tasks has section badges only) |
| C3 | a notification per message; activating it opens the conversation (BUILT 2026-09-25: a message to a conversation that is not open posts one keyed by the conversation, opening the conversation withdraws it; the chat leg reads both on five lanes, its steps last so no typing follows a post) | nothing in the API; `kaya_run` never granted the notifications capability, so no binding but Rust could post (docs/traps.md) |
| C4 | answering from the notification itself (DESIGN: docs/notification-reply-plan.md, R1 ruled 2026-09-25) | notification reply actions: a text field in the notification, the reply as an occurrence |
| C5 | an emoji button beside the compose field (DESIGN: docs/emoji-picker-plan.md, R1-R2 ruled 2026-09-25) | the platform emoji picker (GTK EmojiChooser, the mac character palette, WinUI's emoji panel, the phones' keyboards) |
| C6 | an image attachment shown inline (DESIGN: docs/photo-attach-plan.md, R1-R3 ruled 2026-09-25; the image needs a bounded fit, so display is not "nothing new") | nothing new for display; the photo picker on the phones |
| C7 | swipe a conversation to archive it on the phones (DESIGN: docs/swipe-actions-plan.md, R1-R3 ruled 2026-09-25) | swipe actions |
| C8 | a Search field over the thread; a result jumps to its message (BUILT 2026-09-25: the thread keeps every message and each Return jumps to the next older match in place, as Messages does, rather than filtering the list; the count found `press return` submitting twice on GTK and Compose, docs/traps.md) | nothing new (the search field, `scroll_to_row` into a filtered list) |
| C9 | the connection drops and comes back; messages queue meanwhile (BUILT 2026-09-25: the peer drops after a scripted answer and stays away six seconds; the thread says Offline, a message sent meanwhile is a `Pending` case with a Sending… caption, and on the redial the queue goes out and each becomes `Mine` in place. Pending is its own case because an empty caption holds a line in every sent bubble, seen in the first capture) | nothing new in kaya; the app's reconnect over `post` |

A LATER REVISION carries emoji and images beyond C5 and C6. Colour emoji
inside a message body need nothing from kaya on four platforms; the linux
container very likely lacks a colour emoji font, the missing-librsvg
class (docs/styling-plan.md D6), and the first emoji leg will say so.

Video and audio playback, which the survey lists as must-have for chat,
stay with the video editor (docs/video-editor-plan.md) and are not
staged here.
