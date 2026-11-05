# Design rules for the demo apps

Status: RULED 2026-11-04. The maintainer, on the design approval page
(https://claude.ai/artifact/VRg9U4i2uTfNt16HTzUS9W): "i like your
recommendations", which takes every recommendation the page made: the task
manager's option A, the portfolio's option A, the chat wallpaper edge to
edge, Writing Mode's Markdown drawn styled, and the capsule (below, R2).
docs/looks-plan.md §6 records the rulings and the build. These rules sit under
docs/styling-pass-plan.md's Y1-Y11 (an app skins grounds, pictures, shapes,
tints and states; the controls stay the platform's own; no app branches on
the platform). Y1-Y11 say what an app MAY change; these rules say what a good
use of that freedom looks like, in numbers a capture can be checked against.
Every number is in DIP (points on Apple, dp on Android, DIP on Windows,
logical pixels on GTK).

## R1: The spacing scale

Every inset, spacing and gap an app declares comes from one scale:

| step | DIP | used for |
|---|---|---|
| xs | 4 | the gap between a value and the pill under it; a pill's vertical padding |
| s | 8 | the gap between siblings in a row; a bubble's vertical padding; a pill's horizontal padding; the padding around a header glyph |
| m | 12 | the gap between a glyph and its title; a bubble's horizontal padding; the gap between a bar's rows and its edge |
| l | 16 | the page margin (kaya's window inset default); a card's or tile's padding |
| xl | 24 | the gap between sections of a page; a header band's padding |
| xxl | 32 | the space above a page's large title on a desktop |

No other number. A value off the scale is a mistake to fix, not a choice.

## R2: Padding inside every filled shape

A filled container (a pill, a bubble, a tile, a status strip) always pads
its content, and pads it wider than it is tall:

- **Pill** (one line of text on a fill): vertical 4, horizontal 8
  (`inset (4, 8)`). The horizontal padding is at least twice the vertical.
- **Bubble** (a message): vertical 8, horizontal 12.
- **Tile or card**: 16 on all sides.
- **Strip** (a full-width bar of small text): vertical 4, horizontal 16.

The corner radius follows the height: a shape one line tall is a capsule
(radius = half its height); a taller shape takes the platform's card radius.
This is kaya's, not the app's (RULED 2026-11-04, docs/looks-plan.md §6): every
backend draws a filled container one line tall as a capsule. "One line tall"
is measured: the fill's content (its height less its own inset above and
below) is under one and a half of the platform's body lines at the user's
text size, so a scaled icon or a single label is one line and a label over a
caption is not.

## R3: Grounds go edge to edge, or not at all

A ground (a gradient wash, a wallpaper, a solid band) touches the edges of
the pane it belongs to on both sides, and on the top when it is a header. It
never floats inside the page margin as an inset card with page showing on
all four sides. Measured on a capture: the ground's left and right edges are
the pane's edges, within 1 DIP.

The page content that sits on the plain page keeps the page margin (R1's
16); the ground's own content keeps it too, so text lines up across the
ground's edge.

## R4: The app's colour is spent in one place per screen

Each screen has ONE element that carries the app's or the data's colour
loudly: a header band, a set of tiles, a chart line, an accent strip. Every
other element on that screen is in the platform's neutral colours, with
semantic tints (overdue red, today accent) allowed only on small text.
Two loud elements on one screen (a coloured header over coloured tiles, a
red wash over a red pill over a red line) compete and are a mistake.

## R5: The type hierarchy

At most four text sizes on a screen:

| role | spelling in kaya | use |
|---|---|---|
| large title | `heading` at `text_scale` 1.6, weight 700 | once per screen, the page's name or its one figure |
| section heading | `heading` (the platform's) | a group's name |
| body | `label` | the content |
| caption | `caption` | secondary detail: dates, counts, totals |

A figure that IS the screen (a portfolio total) may take `text_scale` 2.2,
weight 600, in place of the large title. Weight, not colour, makes the
hierarchy; text stays in the primary and secondary colours except for R4's
one place and the semantic tints.

## R6: References

Each demo names a real app it is measured against. The references are for
proportion, rhythm and where the colour goes; no art, icon, branding or
colour value is copied.

| Demo | Reference | What the reference does |
|---|---|---|
| Task manager | Apple Reminders, Things 3 | A plain white or dark page. The list's colour lives in its icon (a white glyph in a coloured circle in Reminders; a coloured glyph in Things) and, in Reminders, in the large bold title. No band, no wash. The smart lists are a grid of rounded tiles, each with its coloured icon, its count large and its name small. |
| Chat | WhatsApp desktop, Messenger | WhatsApp: a solid header bar (the contact and the call buttons), the wallpaper filling the whole conversation pane edge to edge under it, a solid composer bar at the foot. Bubbles have a small radius, padding about 6 by 9, and opaque fills. Messenger: no wallpaper by default; a chat theme colours the whole pane; bubbles are capsules with padding about 8 by 12. |
| Portfolio | The Robinhood web app | A plain page. The total in very large type at the top left, the day's change under it as coloured text, the chart's line in the day's colour with no wash behind it, and a list of holdings at the side where each price sits on a small filled rectangle in its own day's colour. The colour belongs to the data, never to a panel. |
| Editor's Writing Mode | iA Writer, Bear | One centred column about 60 to 70 characters wide in a proportional face, generous line height. The Markdown is kept as text and drawn styled: a heading larger and bold, emphasis in italic, strong in bold, list markers as characters with the item text hanging after them. iA Writer keeps every mark visible but quiet; Bear can hide the marks away from the caret. |

## R7: How a capture is judged

Each review capture is read against R1-R5 before it is published: the
margins and paddings measured on the picture against the scale, the grounds'
edges against the pane's, the loud elements counted, the sizes counted. A
capture that breaks a rule is a defect in the app, or a gap in the framework
written down as one.

## Framework notes

Gaps these rules found. The capsule was ruled and built (R2). The other three
were not ruled and are GAP entries in docs/deferred.md, with options:

- **A data colour on a glyph or a title.** Reminders puts the list's colour
  on its icon and its title. kaya's `color` tint is a fill only (Y7 refuses a
  raw colour on text); a white glyph inside a `filled color` circle is the
  spelling today.
- **A quiet colour for Markdown's marks.** iA Writer greys the `#`, `*` and
  `>` it keeps visible; kaya's rich text left colour runs out of its first
  vocabulary (docs/rich-text-plan.md R3), so Writing Mode draws the marks in
  the text colour.
- **A list paragraph.** A hanging indent for `- ` items needs a list block
  kind, which R3 also deferred; the markers stay characters, as iA Writer
  keeps them.
