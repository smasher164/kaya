# The compose row — the design pass

Status: DESIGN, the maintainer's direction given 2026-09-26: icon-only
buttons are generic over the whole symbol vocabulary, each platform keeps
its own send glyph, the mac shows no send button (Return sends), and no app
ever asks which platform it is on. Waiting on a look at this pass before
anything is built. The research behind it (the stock apps' rows, read from
Signal's and Fractal's source where possible) is summarised in §1.

The chat app's compose row today is a bordered text field, a text button
"😀" and a text button "Send", spaced at the default. Next to any stock
messaging app it reads as three widgets, not one control.

## §1 — What the stock apps share

- One quiet container, not a bordered box: a filled pill on Android
  (Signal: the surface-variant colour, a radius of half the one-line
  height, no outline), a hairline or glass capsule on Apple, the entry's
  own chrome on GNOME (Fractal gives its multi-line view the `entry` CSS
  name). The text inside has no chrome of its own.
- Secondary actions are small borderless icons (emoji, attach, camera),
  inside the container on the phones and beside it on the desktops.
- Exactly one prominent send: an accent-filled circle, an up arrow on
  Apple and a paper plane elsewhere, usually shown only once there is
  text. Mac Messages and Discord show none; Return sends.
- Everything sits on the bottom line as the field grows, and spacing is
  tight.

## §2 — Icon-only buttons (symbol on a button)

`symbol` becomes a button prop over the WHOLE closed vocabulary (the
twenty today, add through home), and a button with a symbol draws its
platform's glyph instead of its title; the title stays as its accessible
name. The vocabulary grows by four:

| symbol | Apple (SF Symbols) | Android (Material) | GNOME | Windows (Segoe Fluent) |
|---|---|---|---|---|
| emoji | face.smiling | Mood | face-smile-symbolic | E76E |
| send | arrow.up | Send (paper plane) | mail-send-symbolic | E724 |
| attach | plus | Add | list-add-symbolic | E710 |
| mic | mic | Mic | audio-input-microphone-symbolic | E720 |

A symbol-only button is drawn borderless (the `plain` role's look) unless
its role says otherwise. Art a symbol cannot name (a brand mark) takes the
button's image bytes, as a section's `icon` already does.

## §3 — The prominent circle

A `prominent` button carrying only a symbol draws as an accent-filled
circle: `arrow.up.circle.fill` on Apple (the glyph Messages uses, which
needs no iOS 17 button shape), Material 3's FilledIconButton on Android,
GTK's `suggested-action circular`, and on Windows the accent button with
circular corners. This is the send button everywhere it is shown.

## §4 — The `composer` container role

A container role in the `filled` role's family: a row holding one text
field (entry, search or textarea) and buttons, drawn as ONE text field in
the platform's own style:

| backend | the container | the field inside | the buttons inside |
|---|---|---|---|
| SwiftUI, iOS | a hairline capsule (glass on iOS 26) | plain | borderless glyphs |
| SwiftUI, macOS | the rounded field chrome Messages uses (glass on 26) | plain | borderless glyphs |
| Compose | a filled pill, surface-variant, radius half the one-line height | no container, no indicator | IconButtons, onSurfaceVariant |
| GTK | the entry's own chrome and focus ring (the `entry` CSS name, as Fractal) | no frame | `.flat` icon buttons |
| WinUI | a Border in the TextBox's own resources (background, border, corner) | borderless | subtle buttons |

Every child sits on the bottom line as the field grows. The app decides
what goes inside and what stays outside by nesting: an iPhone-style row is
`row[ composer[ textarea, emoji ], send ]`, a Signal-style one
`row[ composer[ emoji, textarea, camera ], send ]`. Compose's own
leading/trailing icon slots are NOT the lowering: they centre their icons
vertically (read in the Compose source), which is wrong for a growing
field, so the pill is a laid-out row there as everywhere.

The focused state follows the field: the container draws the platform's
focus treatment (the mac's focus ring, GTK's, the WinUI accent line,
Material's) while the field inside has the focus.

## §5 — The composer's send

A symbol-only `prominent` button placed in or beside a composer, whose
text field `submits`, is that composer's SEND. The action is one on every
platform: Return sends, since the field submits, and the button sends too.
Where the platform's own messaging app shows no send button, kaya shows
none: on macOS the composer's send is not drawn (Mac Messages; Return
sends), and everywhere else it is the §3 circle. The app declares it once
and never asks which platform it runs on; kaya has no such query by
design (app.rs, `Platform`'s note).

Showing send only while there is text is the app's, with `when` on the
draft, and needs nothing new.

## §6 — How a leg sees it

- The symbol: the button's accessible name stays its title, so scenes
  address it as before; `expect_ax` reads the role and name.
- The composer: a gate holds each backend's lowering (the container's
  tokens, the chromeless field, the bottom alignment), since the look is
  pixels no shared observable reads; the captures are the rest.
- The mac's undrawn send is a per-platform presentation no shared scene
  can assert, so the scene sends with Return (as the chat scene already
  does), and a gate holds the macOS arm's omission and the other arms'
  circle.

## §7 — What cannot be matched

Per-app flourishes (WhatsApp's green, the mic morphing into send) and
exact paddings. The target is each platform's own messaging look, not one
look everywhere.

## §8 — Rulings wanted

- **R1:** `composer` as a new container role, and the rule that a
  prominent symbol-only button in a submitting composer is its send,
  undrawn on macOS. RECOMMENDED as written.
- **R2:** the four new symbols and their glyphs (§2). RECOMMENDED as
  written.
