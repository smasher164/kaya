# The media player demo: the design pass (2026-10-17)

Status: RULED 2026-10-17: M1 (Jamendo) and M3 (Python) (the maintainer:
"let's go with jamendo and python"), then the rest as recommended ("accept
the rest as recommended"). Nothing is built. The roadmap card (docs/roadmap/editorial.toml, "The media player")
names the app: a music client styled toward the egui Spotify screenshot the
maintainer saw on 2026-10-08, over a public catalogue, shipping with audio
and Now Playing on every platform, media keys, sliders, tables, the
three-pane window, the search field, the secure field and autofill for
sign-in, the segmented control for its filter chips, and the toast. Two
passes were built for it and both leave their last step to this app: the
styling pass (docs/styling-pass-plan.md Y11 and §6 steps 4 and 5: the demo's
screens in Y11's order, each a review capture on every lane) and network
images (docs/network-images-plan.md N17: album art from a public catalogue
over https, and §6 step 7's review page). docs/media-plan.md is the player
and the media session it plays through. docs/safe-area-plan.md and
docs/network-images-plan.md are the shape of this document; the chat app
(docs/chat-plan.md), the portfolio (docs/portfolio-plan.md) and the task
manager (docs/tasks-plan.md) are the precedents for how a demo is written,
scened and run.

Words used in this file, each as the field uses it:

- A CATALOGUE is a music service's database of artists, albums and tracks,
  reached over an API (a set of web addresses that answer in JSON). A
  STREAM here is the plainest kind: the player is given the https address of
  one audio file and downloads it while playing, asking for pieces with HTTP
  RANGE requests (a header naming a byte span, answered with status 206).
- A CLIENT ID (also API key) is a string a service issues to an
  application, sent with every request so the service can count and limit
  that application's use. It identifies the APP, not a person. SIGNING IN
  is the other thing: a person proving who they are, after which the app
  holds a TOKEN on that person's behalf (OAuth is the usual protocol).
- HERMETIC means a test reaches nothing outside the machine running it, so
  it gives the same answer offline, when the service is down, and in ten
  years. A SNAPSHOT is a small copy of a catalogue's answers and files taken
  once; a MIRROR is a local server that serves the snapshot at addresses
  shaped like the real ones.
- CREATIVE COMMONS (CC) licences let anyone copy a work under conditions
  named by letters: BY (credit the author), SA (share-alike: a changed copy
  carries the same licence), NC (non-commercial use only), ND (no
  derivatives: only verbatim copies). CC0 waives everything. Trimming a
  track to a clip is a derivative, which ND forbids.
- NOW PLAYING is the operating system's own display of what an app is
  playing (Control Centre and the lock screen on Apple, the media
  notification on Android, the GNOME Shell media card through MPRIS, the
  Windows media flyout through its System Media Transport Controls). MEDIA
  KEYS are the keyboard's and headset's play, pause, next and previous
  keys; the system routes them to whichever app holds the media session
  (docs/media-plan.md §5).
- A QUEUE is the ordered list of tracks to play next. GAPLESS playback
  starts the next track with no silence between, which needs the next file
  opened before the current one ends (PRELOADING).
- A SHELF is a single horizontal row of cards that scrolls sideways; a CARD
  GRID wraps cards onto as many lines as they need.

## §0: What exists, what the earlier demos did, and what the catalogues offer

### What the demo's screens need, against the tree at b2a5d252

Read from the tree on 2026-10-17. "Built" means built on all five lanes and
in all nine bindings unless said otherwise.

| screen (Y11's order) | needs | state |
|---|---|---|
| 1. Library sidebar | the panes window (docs/multicolumn-plan.md), two-line rows with rounded art (Y5, Y6), the selected row (Y4), `on_activate` on a stamped row | built |
| 1. Home | cards that take a click as a whole with the platform's hover (Y4), rounded art, the caption role, a fitting grid (`min_column_width`, docs/layout-knobs-plan.md §3) | built for a LIVE grid; a collection's For cannot be laid out as a grid (crates/kaya/src/scene.rs:1552 holds `columns` to the Grid widget, and a For is its own container, scene.rs:7398-7410); a For in a sideways scroll (a shelf) is built (guests/rust/scrollto.rs:63-77) |
| 1. Home | art per card from the network, phases and the fetch helper (docs/network-images-plan.md N2, N7, N8, N12) | built |
| 2. Playlist | a table whose title cell is art beside two lines, the pinned header, the playing track's tinted name (Y5-Y7, tools/scenes/tracks.steps) | built |
| 2. Playlist | a row that plays on double-click or Return | built 2026-10-17 (Y4, §6 step 2): on the macOS native table `on_activate` is the NSTableView's `doubleAction` and Return, `selected` its own selection; since the Y4 amendment (built 2026-10-18) a user's click and the arrows move that selection and tell the app through `selection_changed` / `on_select`; the iOS synthesized tier, Compose and WinUI table rows activate and wear the selection too, and tools/scenes/tracks.steps clicks and reads two album rows on every lane (docs/traps.md, "The table row nobody rendered") |
| 2. Playlist | a context menu on a track (Add to queue, Go to artist) | built for stamped rows (a template's context catalog, docs/traps.md's catalog entries); on the macOS native table UNMEASURED |
| 2. Playlist | track and playlist durations ("3:45", "1 hr 12 min") | NOT BUILT: crates/kaya/src/fmt.rs has date, time, number, percent, currency and timecode, no duration (§2 M9) |
| 3. Gradient header | the gradient ground from one data colour, `image_dominant` (Y2) | built |
| 4. Dock (player bar) | the dock (Y8), the player (docs/media-plan.md §2), a progress slider and a volume slider, transport buttons | dock, player and sliders built; the TRANSPORT SYMBOLS are NOT BUILT: crates/kaya/src/wire.rs's SYMBOLS has 25 entries and none is play, pause, next, previous, shuffle, repeat or volume (§2 M8) |
| 4. Dock | the progress slider moved by the player's position every 250 ms (crates/kaya/src/media.rs `POSITION_TICK_MS`) while the user may be dragging it | NO RULE: every backend applies an app's write at once, mid-gesture (KayaSwiftUI.swift:15166, KayaCompose.kt:22118, gtk.rs:16488, winui/mod.rs:17873), so the thumb jumps back under the finger (§2 M10) |
| 4. Dock, phones | the full player as a sheet with detents | built (docs/sheet-plan.md) |
| 5. Artist page | the image ground with text inside an `overlay` panel (Y3), a round avatar (Y6) | built; the demo's artist page 2026-10-18 (tools/scenes/music_artist.steps): reached from the album header's artist name, full bleed like M15's B, the top tracks as a hugging table and the albums as a shelf |
| all | the media session with next and previous offered, so media keys skip | built: an action in the app's mask reaches it as `session_action` (media.rs:536-549) |
| all | Now Playing artwork for a track whose art came from the network | NOT BUILT: `artwork` is an asset name only (crates/kaya/src/protocol.rs:581-582; media.rs:515-520 panics on anything else) (§2 M7) |
| all | the next track | one source per player (spec.rs:428-439): no queue, no preload, no gapless; the app swaps `source` on `ended` or `next` (§2 M11) |
| Search | the search field, results filtered by the segmented control | built (docs/search-plan.md, docs/segmented-plan.md) |
| all | the toast with an action ("Added to Liked Songs", Undo) | built (docs/toast-plan.md) |
| sign-in | the secure field, autofill's username and password content types | built (docs/secure-entry-plan.md, docs/autofill-plan.md); whether the demo has anything to sign in to is §2 M4 |
| attribution | a link per track to its page at the source, the licence named | built (the `link` role) |

### How the earlier demos were built

| demo | language | why that language | how it runs on the lanes |
|---|---|---|---|
| the editor (docs/editor-plan.md) | Go | "an editor in Rust would be kaya testing itself" | one Go guest under guests/go/editor, alone between drains on every lane |
| the portfolio (docs/portfolio-plan.md) | Python | "one other language just for diversity's sake", the dynamic binding with the ambient transaction | one file, guests/python/portfolio.py; the phones since 2026-08-30 through the Python host (tools/ios/run-sim.py stages `PYTHON_SCENES`, tools/android/run-emulator.py copies the scene files into android/pyhost) |
| the task manager (docs/tasks-plan.md) | Rust | the first app, the reference binding | guests/rust/tasks.rs, the same example under several scripts (`taskspersist`, `tasksrtl`, `tasksbig`) through tools/lib/lanes/mac.py's `HAND_QUEUED` |
| the chat app (docs/chat-plan.md R1) | Go | "one of the three languages that run on all five lanes"; "Rust would test nothing new" | guests/go/chat, its peer a server inside the app on loopback; `("chat", ("go",))` alone between drains on the mac, tools/lib/lanes/win.py's `GO_ONLY_SCENES`, a `chatgo` bundle on iOS |
| the video editor (docs/video-editor-plan.md) | Rust, ruled | | not built |

Each demo is ONE language, and its scenes are shared scripts in tools/scenes
read byte for byte on every lane that runs that language. The toolkit
surfaces a demo uses are held in all nine bindings by the sugar census
(invariants 1 and 2), whatever the demo is written in. The languages that run
on all five lanes are Rust, Go and Python; Swift runs on the mac and iOS,
Java on the three desktops and Android, C# and JS on the three desktops, OCaml
and Haskell on the mac and linux.

### The catalogues, surveyed and probed (MEASURED 2026-10-17 from the desk)

Every row below was probed with curl from the mac on 2026-10-17 between
about 17:30 and 18:00 UTC, with a User-Agent naming the probe; timings are
total seconds from this desk; image sizes were read from the JPEG, PNG or
GIF header; audio by a ranged request for its first 200 KB with the first
MPEG frame's header parsed. Nothing was registered: no account was made at
any service.

| catalogue | who runs it | audio | art | key or account | terms that matter | may a snapshot be committed | measured |
|---|---|---|---|---|---|---|---|
| Jamendo API v3 | Jamendo S.A., Luxembourg | whole tracks, direct https MP3: `mp31` 96 kbps constant, `mp32` about 192 kbps variable; 0 redirects; Range honoured (206) | album covers 25 to 600 px square by a `width` parameter (300, 500, 600 measured JPEG; one album's original is a GIF at every width); artist images 500 px | a `client_id` on every API call, free and self-serve for non-commercial use, 35,000 requests a month; the audio and image hosts need none | credentials "strictly personal" and never shared; credit the artist and Jamendo with a backlink per item; no app "specifically designed to cache the content" or offer offline access; not to replicate Jamendo's own look | per track: CC BY and BY-SA yes (trimmed too), ND only verbatim, NC no | API answers in 0.4 to 1.0 s; every client id circulating in tutorials is dead (`your_client_id` invalid, `709fa152` "suspended", `b6747d04` "usage limits are exceeded"); a 272 s track's `mp31` is 3,291,136 bytes, a 600 px cover 35,177 bytes, an artist image 18,421 bytes |
| Openverse | the WordPress Foundation (once Creative Commons' search) | Jamendo's storage addresses, as above | a 300x300 thumbnail; Jamendo's keyless image host to 600 | none: anonymous 20 requests a minute, 200 a day, 20 results a page (read off the response headers); free registration raises them | per-source licences; ready-made attribution sentences and the Jamendo backlink | filters to `license=by,by-sa` on the server | 200 in 2.0 s, 18 KB for 10 results; no album, artist or playlist endpoints; Jamendo rows last indexed about 2022 |
| Internet Archive netlabels | the Internet Archive | MP3 originals (128 kbps measured) and 64 kbps copies; one redirect to a storage node; Range honoured; https throughout | the uploaded cover, small and not always square (284x270, 300x300 measured), a 180 px tile; no resizing | none | per item `licenseurl`, often blank | CC BY 3.0 alone: 998 netlabel items | search 0.6 s, item 0.7 s, audio 1.1 s; "artist" is free text and there are no artist images or playlists |
| Free Music Archive | Tribe of Noise, Netherlands | no API (shut down; `/api` answers 404) | | | no hotlinking, no scraping; "use FMA music provided you host it on your own server" | per track CC | site up, API gone |
| MusicBrainz + Cover Art Archive | the MetaBrainz Foundation | none | 250, 500, 1200 px and the original (3500 px measured); two redirects; one 500 on a first try | none; a User-Agent naming the app and 1 request a second | data CC0; covers carry no licence ("use at your own risk") | covers no | MusicBrainz 1.1 s; covers 2 to 3 s cold |
| ccMixter | ArtisTech Media | MP3 that answers 403 unless the request claims to come from ccmixter.org (a Referer header) | avatars only | none | per upload CC | CC BY uploads yes | a native player sends no Referer, so the audio does not play |
| Audius | Audius Inc. | 320 kbps MP3 through two redirects to an address that expires in 5 minutes | 150, 480, 1000 px; artist pictures and wide cover photos | an `app_name` only (measured); an optional free key | the artists' own copyrighted music under Audius' terms | no | 0.5 to 2.3 s |
| iTunes Search | Apple | 30 s AAC previews only | any size by rewriting the address (100, 300, 600 measured) | none, about 20 a minute | promotion of the store only, no redistribution | no | 0.5 to 0.9 s |
| Spotify Web API | Spotify | none for new apps since 2024-11-27 | 64, 300, 640 | an account and an OAuth token | no redistribution | no | 401 without a token |
| SoundCloud | SoundCloud | needs OAuth | | a registered app (registration restricted) | copyrighted | no | 401 without a token |
| Wikimedia Commons, Freesound | Wikimedia; Universitat Pompeu Fabra | single files and sounds, no albums | none | none; Freesound a key | per file | CC0, BY, BY-SA files yes | not a catalogue |

What the survey settles: Jamendo is the one free catalogue shaped like
Spotify's (artists with several albums, square covers per album, artist
images, playlists, featured charts by genre) with whole tracks a native
player can stream from a plain https address, and every track labelled with
its licence, so the redistributable part can be picked by a program. Its one
cost is the client id, which its terms forbid sharing, so none may be in the
repository. MEASURED from Openverse's index: the Jamendo artist "Rataxes" has
37 tracks over 8 albums, 7 albums CC BY; Kevin MacLeod's albums there are
mostly BY-NC-ND. Licences vary by album and by artist, so a snapshot must be
chosen per track AND per album.

## §1: The app, in one page

A music client in the shape of the reference (docs/styling-pass-plan.md §0,
"The reference look"), with these screens:

- DESKTOPS: a three-pane window. The SIDEBAR holds Home, Search and Your
  Library as destinations, then the user's saved playlists and albums as
  two-line rows with rounded art, the one being viewed selected. The CONTENT
  pane is a navigation stack: Home, a playlist or album, an artist, search
  results. The THIRD pane is Now Playing: the playing track's large art, its
  two lines, the licence and its link, then the queue. The DOCK spans the
  window's foot under all three: the playing track's art and two lines,
  previous, play or pause, next, shuffle and repeat, the progress slider with
  elapsed and total times, and volume.
- PHONES: the window's sections (Home, Search, Library) in the tab bar, the
  dock above it (iOS 26's tab bar accessory where available, Y8), and the
  full player as a sheet with detents when the dock is tapped.
- HOME: shelves titled by genre or chart ("Popular this week", "Jazz",
  "Electronic"), each a row of cards (rounded art, title, caption), the card
  under the pointer lightened, a click opening the album.
- PLAYLIST OR ALBUM: the gradient header from the cover's dominant colour,
  the large cover, the title in the heading role, a caption ("Rataxes · 2015
  · 6 songs, 24 min"), a play button, then the track table: index, title cell
  (art and two lines), album, duration; the playing row's name tinted
  accent; double-click or Return plays from that row.
- ARTIST: the artist image as the page's ground with the name inside an
  `overlay` panel, a round avatar, then the artist's albums as a shelf and
  the top tracks as a table.
- SEARCH: the search field, the segmented control (All, Artists, Albums,
  Tracks), results grouped under it.
- TOASTS: "Added to Liked Songs" with Undo; "Couldn't reach the catalogue"
  with Retry.
- LIKED SONGS: the app's own list, kept in the app's preferences store
  (docs/tasks-s4-plan.md's precedent), never on the catalogue.

The app owns the catalogue client, the queue, shuffle and repeat, the liked
songs and every request; kaya owns the layout, the player and its decoding,
the session, the images' decoding and cache, and the slider's gesture. The
catalogue is reached through ONE interface in the app with one real
implementation and the mirror's address in its place under the harness (M2),
so the scenes run the same parsing, fetching and playing code the person
runs by hand.

## §2: The rulings (PROPOSED 2026-10-17)

### M1: The catalogue is Jamendo, through its own API, with the person's own client id (RULED 2026-10-17)

RECOMMEND Jamendo's API v3 for the app run by hand, with a client id the
person registers for free at Jamendo's developer portal and gives the app:
on the desktops through an environment variable (`KAYA_JAMENDO_CLIENT_ID`),
on the phones and the desktops alike through a one-field "Connect a
catalogue" sheet whose value the app keeps in its preferences store. With no
id the app opens on the bundled sampler (the snapshot of M2, read from the
app's own assets), says so in one line on Home, and offers the sheet. Audio
streams from Jamendo's storage host as `mp32` (about 192 kbps); covers come
from its image host at 300 px for rows and cards and 600 px for headers and
Now Playing; the artist image at 500 px. Every track's page shows its
licence by name and links to its Jamendo page, which is the terms' credit
and backlink clause.

Why: §0's survey. Jamendo is the only free catalogue with the reference's
structure (artists, several albums each, per-album covers, artist images,
playlists, featured charts) and whole tracks on plain https addresses that
every platform's player opens, Range included. Its terms make the client id
personal, so the repository cannot carry one, which is also why every public
id is dead: an id in a public repository gets used up by strangers. The
sampler keeps the app useful to someone who has not registered, and costs
nothing beyond M2's snapshot, which exists for the lanes anyway.

Two points of the terms the maintainer should see before ruling. (a)
"Applications must not be specifically designed to cache the content nor
offering an offline access to the content": the app caches nothing from the
live catalogue (images are cached decoded in memory by kaya, N10, which is a
display cache, not offline access); the sampler is a separate set of files
taken under their CC licences (M2), which govern redistribution whatever the
API's terms say about apps. (b) "not ... confusingly similar to the design
or look and feel" of Jamendo: the reference look is Spotify's, not
Jamendo's.

Alternatives:
- (b) OPENVERSE as the live catalogue: no key at all, licence filtering on
  the server, attribution sentences ready-made. Refused as the default
  because it has no album, artist or playlist entities (an album's tracklist
  is a search), its Jamendo index stops about 2022, and 200 anonymous
  requests a day is a few minutes of browsing. It could serve as the no-id
  mode instead of the sampler; that is a second live client to write and
  hold green by hand.
- (c) INTERNET ARCHIVE netlabels: no key, CC BY material by the thousand,
  but small and often non-square covers, artists as free text and no artist
  images, so the artist page and the Home grid would be a curated fiction.
- (d) AUDIUS: current, rich, 320 kbps and keyless with an app name, but the
  music is copyrighted, so nothing can be snapshotted and the lanes would
  test against different music than the person hears.
- Refused: Spotify and SoundCloud (no audio for new apps, OAuth), iTunes
  Search (30 s previews, promotion only), MusicBrainz with the Cover Art
  Archive (no audio; covers not redistributable), Free Music Archive (no
  API), ccMixter (audio refused to a request without the site's Referer).

### M2: The lanes run against a mirror of a Jamendo snapshot, served by the lane's media server (RULED 2026-10-17)

RECOMMEND a snapshot of Jamendo's answers and files, committed under
guests/assets as a new family `catalogue`, served by the lane's media server
(tools/media-server.py) at addresses SHAPED LIKE JAMENDO'S, and the app
pointed at it under the harness by the address the lanes already hand every
media guest (`KAYA_MEDIA_URL`, read by guests/rust/netimage_http.rs today).

- WHAT IS IN IT: three artists, two albums each, two tracks from each album
  (twelve tracks), every track AND its album CC BY or CC BY-SA, plus each
  album's cover at 300 and 600 px, and the
  JSON answers for exactly the requests the app makes (the featured charts
  for Home, each album and its tracks, each artist and their albums, two
  searches, one playlist). Covers that Jamendo serves as GIF are transcoded
  to JPEG, or the album is skipped. RULED 2026-10-17 (the maintainer: "im
  okay with your recommendations"): no Jamendo artist image is in it, since
  they carry no licence and Kellee Maize's was the cover of her BY-NC-ND
  album "Crown"; each artist's image is the cover of the first of that
  artist's albums in the snapshot whose every track is CC BY or BY-SA,
  named in `_snapshot.artist_images`, and the mirror's
  `/catalogue/usercontent?type=artist&...` address answers with that
  cover's bytes. The generator refuses an artist with no such album.
- CLIPS, NOT WHOLE TRACKS: each track trimmed to 20 s and kept as Jamendo's
  own `mp31` MP3 (96 kbps): about 240 KB a clip, about 2.9 MB for twelve,
  with covers and artist images about 0.8 MB more. Whole tracks would be 3 to
  5 MB each, 40 to 60 MB in all, and the asset root is staged whole onto
  every lane and into every phone bundle (tools/check-assets.py). The JSON's
  durations are the clips', so the table, the slider and the player agree.
- THE ADDRESSES KEEP JAMENDO'S SHAPE: the mirror answers
  `/catalogue/v3.0/albums/tracks?...`, `/catalogue/storage/?trackid=<id>&format=mp31`
  with `audio/mpeg` and no file extension, and
  `/catalogue/usercontent?type=album&id=<id>&width=600`, because a player
  that infers a type from a file extension (AVFoundation, Media Foundation)
  is exactly what the extensionless live address would break, and a mirror
  serving `track.mp3` would pass a scene the person's app then fails. The
  server grows a query-routed family and the `application/json` type.
- THE SNAPSHOT IS MADE BY A TOOL, a `gen-catalogue.py` beside
  tools/gen-covers.py, run once by the maintainer with his own client id
  (never stored): it fetches, refuses any track or album whose
  `license_ccurl` is not CC BY or CC BY-SA, trims with the dev shell's FFmpeg,
  transcodes GIFs, rewrites every address in the JSON to the mirror's
  relative form, and writes the family's README with an ATTRIBUTION table
  (title, artist, album, source page, licence, "trimmed to 20 s"). Its
  `--check` mode reads only the committed files (the network is not
  hermetic): every address in the JSON resolves to a file, every file is
  named by the JSON, every track's licence is in the allowed set.
- BY HAND, THE SAMPLER (M1's no-id mode) reads the same family through
  `asset(name)` with no server: the app's catalogue client takes a FETCH
  function (N12's shape), and the sampler's fetch maps the mirror's addresses
  to asset reads.

Why: the chat app's rule (a real network path through the guest's own
stack, nothing outside the machine) and the media suite's (a local server
with Range, never the internet, docs/media-plan.md §7a). A lane that reached
Jamendo would go red when Jamendo is slow, when the free quota runs out, or
when an artist withdraws an album, and could not carry a client id at all.

Alternatives: (b) the lanes run against the assets with no server, as the
sampler does: the network images helper, the player's https path and the
failure paths would then go unexercised by the demo's own scenes. (c) whole
tracks: 40 to 60 MB in every bundle. (d) synthetic music (tones, like the
media suite's clips) with synthetic covers: no licence question at all, but
the review page would show test patterns where the reference shows albums,
and the dominant colour and the gradient would be read off flat fills.

### M3: The demo is written in Python (RULED 2026-10-17)

RECOMMEND Python, as one file `music.py` beside guests/python/portfolio.py,
run on all five lanes through the Python host as the portfolio is.

Why: the demo must run on all five lanes, because every screen is a review
capture on every lane (Y11, §6), and only Rust, Go and Python do. Rust wrote
the task manager and will write the video editor; Go wrote the editor and
the chat app. Python wrote one app, and that app reads no network, starts no
background work and plays nothing. This one exercises exactly the Python
surfaces no app has: the network images helper's default fetch over the
standard library (`urllib.request`, docs/network-images-plan.md N16), a
background thread posting results into the ambient transaction, the player's
occurrences and the session's handlers in the dynamic binding, the skin's
template props in Python's row templates, and the second Python app on the
phones' Python host. The surfaces it uses stay held in all nine bindings by
the census, whatever the demo is written in.

Risk, to be measured first (§7): whether the CPython embedded in the phone
bundles verifies https certificates with the standard library alone. The
lanes do not depend on it (the mirror is plain http, M2), only the person's
hand run on a phone. If it does not, the app's fetch loads a CA bundle file
shipped with the app, a dependency to rule then.

Alternatives: (b) Go, the safest https on every platform (its standard
library reads the system's roots on iOS and Android), at the cost of a third
Go app testing what chat already tested; (c) Rust, whose fetch is the pinned
`ureq` with its own bundled roots, at the cost of "Rust would test nothing
new" (docs/chat-plan.md R1); (d) Java, a language no demo has used, on four
lanes, with iOS missing from every review capture; (e) Swift, likewise new,
on two lanes.

### M4: No account and no sign-in; the only credential is the catalogue's client id (RULED 2026-10-17)

RECOMMEND that the demo has no sign-in. Jamendo's reads need no person, only
the app's client id (M1), and the person enters that once on the "Connect a
catalogue" sheet in a SECURE FIELD (docs/secure-entry-plan.md), since the
terms call it personal and it should not sit on screen. The field takes no
autofill content type, because a client id is not a username or password and
a password manager offering one would be wrong. Liked songs and the library
are the app's own, local. The roadmap line's "the secure field and autofill
for sign-in" becomes "the secure field for the catalogue's key"; autofill's
first app home stays the proposed password manager (docs/roadmap/editorial.toml,
"3. A password manager"), where a sign-in is the subject.

Why, from zero: signing in to Jamendo as a person (its "Jamendo Connect",
OAuth) is only needed for the person's own favourites and playlists on
Jamendo. OAuth on a native app means opening the service's sign-in page in
the platform's web authentication session (ASWebAuthenticationSession on
Apple, Custom Tabs on Android, the system browser with a loopback redirect on
the desktops) and keeping the returned token in the platform's secure store
(the Keychain, Android's Keystore, Windows' Credential Locker, libsecret).
kaya has neither: the web authentication session is not on the roadmap and
the secure store is the unbuilt "Biometrics and secure storage (keychain)"
feature (docs/roadmap/features.toml, `biometrics`, cost L). A sign-in form
that signs into nothing would be a prop, which this repository does not
ship.

Alternatives: (b) Jamendo Connect for real: two new subsystems (the web
authentication session and the secure store), each L, before the demo; (c) a
username-and-password form against the lane's mirror only: refused, it signs
into nothing a person can use.

### M5: The appearance follows the system, both shown on the review page (CARRIED, not asked)

Y11 ruled it on 2026-10-15: the demo declares no `appearance` and follows
the system; the review page shows every screen in light and in dark. The
lanes run both through `KAYA_APPEARANCE` (the dark legs' precedent,
tools/lib/lanes/mac.py's `DARK_LEGS`).

### M6: Three panes on the desktops, sections and the dock on the phones (RULED 2026-10-17)

AMENDED 2026-10-20 by M16 (12), "no third pane for now": the desktops are a
sidebar and a content stack, and the full player is the dock alone there.

RECOMMEND §1's shape: `panes` with a sidebar, a content stack and a Now
Playing pane on the desktops (the pane ladder collapses the third pane first
on a narrow window, docs/multicolumn-plan.md); sections Home, Search and
Library on the phones, where the third pane is the player sheet. The dock is
attached once to the window and hidden while nothing has played.

Why: it is the reference's anatomy, and the roadmap card names the
three-pane window. Spotify's own right-hand "Now playing view" is the third
pane's model.

Alternatives: (b) two panes, Now Playing only in the dock and a sheet
everywhere: simpler, and the three-pane window would go unused by any demo;
(c) one window per screen: no platform's music app does that.

### M7: Now Playing artwork from the app's bytes (a GAP) (RULED 2026-10-17)

RECOMMEND that the session's `artwork` take what an image's `source` takes:
an asset name OR bytes the app registered (the content-keyed bytes network
images write, docs/network-images-plan.md N7, N10), so the art the app
downloaded for its dock is the art the lock screen shows. Per platform:

| platform | artwork from bytes |
|---|---|
| macOS, iOS | `MPMediaItemArtwork(boundsSize:requestHandler:)` answering an NSImage or UIImage decoded from the bytes |
| Android | media3 `MediaMetadata.Builder.setArtworkData(bytes, PICTURE_TYPE_FRONT_COVER)` |
| GTK (MPRIS) | `mpris:artUrl` takes only a URL, so kaya writes the bytes once per content id to a file in the app's cache directory and names it `file://`, removed at exit |
| WinUI | `SystemMediaTransportControlsDisplayUpdater.Thumbnail` from `RandomAccessStreamReference.CreateFromStream` over an in-memory stream |

Why: today the lock screen and the media flyout can show only an album
bundled with the app, so every catalogue app shows the wrong or no art.
Taking the same bytes the image takes reuses the content id and N1's rule
(kaya fetches nothing).

Alternatives: (b) artwork by https address, which each platform but GTK
would fetch itself: refused by N1 (no HTTP in kaya) and it would fetch every
cover twice; (c) no artwork for network art: the demo's Now Playing would
show a blank square on every platform.

BUILT 2026-10-17: `set_session`'s `artwork` is a Str asset name (empty for
none) or a Blob of the picture's bytes, on the TX record and on the apply
record (the spec hash did not move: both fields were already values); the
core resolves the name to a file URL and sends bytes on as the blob. The
binding spellings: Rust `artwork_bytes(&bytes or &asset)`, Python and JS
`artwork=` taking a str, bytes or Asset, Go `ArtworkBytes([]byte)`, C#
`artworkBytes:`, Java `artwork(byte[])` and `artwork(Asset)`, Swift
`artworkData:`, OCaml `?artwork_bytes`, Haskell `SessionArtworkBytes`; the C
floor needs nothing, since `kaya_tx_set_session` takes a `kaya_blob(...)`.
`expect_now_playing_art RRGGBB|none` reads the picture the SYSTEM holds at
half its width and a tenth of its height within 16 per channel (MPNowPlaying
InfoCenter's artwork on Apple, MPRIS `mpris:artUrl`'s file on GTK, the
session manager's thumbnail on Windows, the platform MediaController's
bitmap on Android); tools/scenes/media_session.steps declares
covers/cover-600.jpg by name and, on `next`, covers/cover-320.jpg's bytes.
MEASURED 2026-10-17: Android's system copy of the 600 px cover is 300x300
(so the read is a colour, never a size); WinUI's thumbnail made with
`RandomAccessStreamReference::CreateFromUri` on the asset's file:// URL
reached the session manager as no thumbnail at all, so both routes now
write the bytes into an in-memory stream (docs/traps.md, the thumbnail a
file URL never gave).

### M8: The transport symbols join the symbol vocabulary (a GAP) (RULED 2026-10-17)

RECOMMEND ten symbols in crates/kaya/src/wire.rs's SYMBOLS, each the
platform's own glyph, checked against each platform's floor by
tools/check-symbols.py and held across the six files by
tools/check-symbol-parity.py:

| name | SF Symbols | Material | Adwaita | Segoe Fluent Icons |
|---|---|---|---|---|
| `play` | play.fill | play_arrow | media-playback-start-symbolic | Play (E768) |
| `pause` | pause.fill | pause | media-playback-pause-symbolic | Pause (E769) |
| `next` | forward.end.fill | skip_next | media-skip-forward-symbolic | Next (E893) |
| `previous` | backward.end.fill | skip_previous | media-skip-backward-symbolic | Previous (E892) |
| `shuffle` | shuffle | shuffle | media-playlist-shuffle-symbolic | Shuffle (E8B1) |
| `repeat` | repeat | repeat | media-playlist-repeat-symbolic | RepeatAll (E8EE) |
| `repeat_one` | repeat.1 | repeat_one | media-playlist-repeat-song-symbolic | RepeatOne (E8ED) |
| `volume` | speaker.wave.2.fill | volume_up | audio-volume-high-symbolic | Volume (E767) |
| `queue` | list.bullet | queue_music | view-list-symbolic | List (EA37) |
| `favorite` | heart | FavoriteBorder | emote-love-symbolic | Heart (EB51) |

BUILT 2026-10-17 (wire values 26-35). MEASURED 2026-10-17 against the
installed sets: every SF name is in this mac's name_availability.plist at
macOS 10.15 / iOS 13 (speaker.wave.2.fill at 11 / 14), under kaya's floor;
the Material names are classes in material-icons-core and -extended 1.7.8
(`VolumeUp` and `QueueMusic` through `Icons.AutoMirrored.Filled`, the plain
ones deprecated); the Adwaita names are files in the linux image's
adwaita-icon-theme 51.0 (Adwaita has no heart but the filled
`emote-love-symbolic`); the Fluent members are the `Symbol` enum's (Play
E102, Pause E103, Next E101, Previous E100, Shuffle E14B, RepeatAll E1CD,
RepeatOne E1CC, Volume E15D, List E14C) and Heart is the glyph EB51, every
code point present in the VM's SegoeIcons.ttf and segmdl2.ttf. Read back on
every lane by tools/scenes/menus.steps' View menu. The filled state, RULED
2026-10-17 on the checkbox and BUILT the same day: role `toggle` (9) draws a
checkbox as the platform's toggle button around its `symbol` (SwiftUI
`Toggle` in the button style, GtkToggleButton, WinUI ToggleButton, Compose
IconToggleButton), filled while on where the symbol has a filled form (SF
heart.fill, Material Favorite, Fluent EB52; Adwaita's one heart is filled,
so GTK shows the pressed look); its AX word is `toggle`, and
tools/scenes/a11y.steps reads and flips `checkbox@favorite` (docs/deferred.md,
the filled favourite). Shuffle uses it; repeat stays a button whose symbol
the app swaps. The existing `star` stays the generic favourite.

Why: a player bar of text buttons ("Play", "Next") is not the reference and
not any platform's music app; the chat composer's icon-only buttons are the
precedent for a symbol with an accessibility label.

Alternative: the app ships its own glyph images: refused by
docs/styling-plan.md's symbol rule (symbols are the platform's).

### M9: A positional duration formatter (a GAP) (RULED 2026-10-17)

RECOMMEND `format_duration(ms)` answering positional time, "3:45" or
"1:02:03", in the locale's own digits (Arabic-Indic digits under `ar`, the
format scene's precedent), composed by the core from the number formatter on
every platform so the five lanes print one string. The playlist's total
("6 songs, 24 min", "about 3 hr") is the app's own catalog message with plural
arguments (docs/compliance-plan.md §2.4), not a formatter.

Why: every track row, the dock's two times and the header's caption need it;
an app spelling `f"{m}:{s:02}"` prints European digits in an Arabic shell,
which tasksrtl's discipline refuses. Apple has a positional formatter
(`Duration.formatted(.time(pattern:))`, `DateComponentsFormatter`), Android
has `DateUtils.formatElapsedTime`, glibc and Windows.Globalization have none,
so composing it in the core from the number formatter's digits is the one
spelling all five can share.

Alternatives: (b) the native positional formatter where one exists and the
core's elsewhere: two outputs that may differ by a separator; (c) none, the
app composes it: the Arabic shell shows mixed digits.

BUILT 2026-10-17: `crate::fmt::duration(ms)` truncates to whole seconds
and maps the ASCII digits of `M:SS` or `H:MM:SS` onto the ten digits the
platform's number formatter writes for 0 to 9, refusing a formatter that
writes anything but one digit; the C floor's `kaya_fmt_duration` refuses a
negative `ms` through kaya_fault, and the door is `duration` in all nine
(`FormatDuration` on Go, `fmtDuration` on Haskell, `Fmt.Duration` on C#),
held by check-sugar-surface's formatter rows. tools/scenes/format.steps and
formatar.steps read labels 14 and 15 (`3:05`, `1:02:03`) against the
platform's own number formatter asked digit by digit, so the Arabic shell
reads `٣:٠٥` (watched red with the digit map cut: `label#14 reads "3:05",
wanted "٣:٠٥"`); each lane's scene holds the duration to that lane's own
number formatter's digits, whatever they are.

### M10: An app's write to a slider waits while the user's gesture is live (a GAP, measured first) (RULED 2026-10-17)

RECOMMEND one rule on all four backends: while a pointer or keyboard gesture
is driving a slider (the same "is a pointer driving" each backend already
reads for the committed value, tools/check-slider-commit.py), a write from
the app to `value` is held, and the last held value is applied when the
gesture ends, unless the gesture's own commit superseded it. The app then
binds the progress slider to the player's position with no bookkeeping, and
seeks on `value_committed`.

Why: today every backend applies the write at once (§0), so a playing
track's 250 ms position ticks pull the thumb back under the user's finger
while they scrub. The app can almost avoid it alone (ignore ticks between a
non-final `value_changed` and the commit), but a press that has not moved yet
has sent nothing, and every app with a playhead would re-derive the same
rule; the video editor's playhead is the second.

Alternatives: (b) the app's rule, documented, no kaya change; (c) a
`scrubbing` reading the app can ask: refused, it is the app's bookkeeping
moved behind a getter. To be measured before the ruling's build: on each
backend, the thumb under a held pointer while the app writes (the jump is
expected on SwiftUI's `updateNSView` and Compose's controlled slider; GTK and
WinUI may already ignore a programmatic set during a drag).

BUILT 2026-10-17, MEASURED with each arm's hold cut out: every backend moved
the thumb to the app's write under a held pointer, tools/scenes/sliders.steps
reading `slider#0 holds "25", wanted "60"` on the mac, on GTK under x11 and
wayland and on WinUI, and the same on iOS and Android before their gesture
reads were right; GTK and WinUI ignore no programmatic set during a drag. The gesture is each platform's own: AppKit's tracking
loop (the mac's `hold` drives the arm's gesture doors in process, since a
posted press ends AppKit's loop at once and a real one would take the host's
cursor), UISlider's `isTracking` under the XCUITest driver's held touch,
GtkRange under the lane's real pointer (xdotool, wlpointer), the WinUI
Slider under the VM's real cursor, and a raw pointer-down on Compose's
Slider. A write that arrives meanwhile is held; a gesture that moved nothing
ends with it shown and commits nothing, and one that moved commits its own
value over it. `hold slider#0 [at <value>]` and `release slider#0` are the
scene verbs in all three harnesses; the Windows sliders legs joined the
lane's EXCLUSIVE set, since its real button collides across the pool
(docs/traps.md, the slider held under a pointer). check-slider-commit holds
the rule's fifteen points across the five arms, and a cut applying the write
at once in each arm is watched red.

### M11: The queue is the app's; no gapless, no preload (RULED 2026-10-17)

RECOMMEND that the app keep the queue, shuffle and repeat, and move one
player to the next track by setting its `source` on `ended`, on the dock's
next button and on the session's `next` action (offered in the session's
mask so media keys skip, media.rs:536-549). Gapless playback and preloading
the next item are deferred to the ledger (KEY: gapless, preload, queue).

Why: a music app's queue is its own (shuffle orders, repeat-one, "play
next"), and docs/media-plan.md §2 rule 3 already says the app owns play
state. Gapless needs a second item opened before the first ends
(AVQueuePlayer, ExoPlayer's playlist, playbin's `about-to-finish`,
MediaPlaybackList), a new object on four platforms that this catalogue's
albums do not need: few are mixed without gaps. The gap between two tracks
is measured on each lane (§7) and goes on the review page.

### M12: Home's cards are a live fitting grid per shelf; a collection laid out as a grid is deferred (RULED 2026-10-17)

RECOMMEND that each Home shelf be a LIVE `grid` with `min_column_width`
(docs/layout-knobs-plan.md §3), rebuilt in a transaction when the shelf's
answer arrives, its cards' art live images fetched by the app's helper; at
most twelve cards a shelf. A collection's For laid out as a grid (a lazily
realized grid of hundreds) is deferred (KEY: For as a grid, lazy grid,
LazyVGrid, GridView, ItemsRepeater) with its trigger: a "Show all" page or
the photo gallery demo.

Why: the reference's Home shows a dozen cards per shelf; a live grid holds
that with no new kind, and the cards scene (tools/scenes/cards.steps) already
proves the live grid's cards, hover and selection on every lane. A lazy grid
is a new layout on four platforms (SwiftUI `LazyVGrid`, Compose
`LazyVerticalGrid`, GTK `GtkGridView`, WinUI `ItemsRepeater` with
`UniformGridLayout`) whose virtualization rules (docs/virtualization-plan.md)
would need their own pass.

Alternatives: (b) build the lazy grid now, a pass of its own (L); (c) shelves
as sideways-scrolling Fors (built): the platform's sideways scroll with a
mouse is awkward on the desktops and Spotify's desktop app does not use it,
though its phone app does; available to the app on the phones if the
maintainer prefers.

### M13: The skin's choices, as the demo uses them (RULED 2026-10-17)

RECOMMEND, all within rulings already made: cards and sidebar rows `neutral`
filled with the platform's hover (Y4), art `rounded` and the artist avatar
`circle` (Y6), the playlist header's colour from `image_dominant` of the
600 px cover (Y2), the artist page's image ground with its name and follower
line inside an `overlay` panel (Y3), the playing row's name tinted `accent`
(Y7), the brand accent left at kaya's default (no Spotify green, which would
be impersonating a brand on a public page).

Why: the demo applies the pass, it does not extend it.

## §3: Per platform

| | macOS | iOS | GTK | WinUI | Android |
|---|---|---|---|---|---|
| window | panes, three columns, pane ladder | sections + dock as the tab bar's accessory (iOS 26) or a bottom inset | panes in AdwNavigationSplitView, dock as AdwToolbarView's bottom bar | NavigationView + a Grid row for the dock | sections + dock above the NavigationBar |
| full player | the third pane | a sheet with detents from the dock's `on_activate` | the third pane | the third pane | a sheet |
| audio from Jamendo's extensionless MP3 address | to be measured (AVURLAsset reads the type from the server's `audio/mpeg`) | the same | to be measured (souphttpsrc, typefind) | to be measured (Media Foundation's byte-stream handler by content type) | to be measured (media3's extractor sniffing) |
| background playback | n/a | the `audio` background mode in the Python host's Info.plist (tools/ios/run-sim.py `make_bundle` writes it for a bundle whose app sets a session; the Python host is shared by every Python scene) | n/a | n/a | the media session's foreground service (docs/media-plan.md §5) |
| media keys and Now Playing | MPRemoteCommandCenter, `playbackState` | the same, lock screen | MPRIS2, GNOME's media card | SMTC | media3 MediaSession, the media notification |
| artwork from bytes (M7) | MPMediaItemArtwork | the same | a cache file, `file://` | an in-memory stream | `setArtworkData` |
| table row activation | the native table's double-click and Return, a click and the arrows reporting `selection_changed`: built (Y4, AMENDED 2026-10-17) | the synthesized tier's tap, which reports the pick first | built | built | built |

## §4: The wire and the sweep

The gaps, if ruled as recommended, move the spec and reach every binding
(invariant 2): M7 widens `set_session`'s `artwork` to an image source (the
spec hash moves; all nine bindings and the C floor take bytes there, Python's
`artwork=` keyword, Rust's builder, and so on); M8 adds ten values to the
symbol enum (generated into every binding; the six hand-copied tables held
by check-symbol-parity); M9 adds one function to the formatter door in all
nine and the C floor (held by check-sugar-surface's formatter rows); M10
changes no surface. M1-M6 and M11-M13 change nothing in kaya.

| binding | M7 artwork bytes | M8 symbols | M9 duration |
|---|---|---|---|
| Rust | do | do (generated) | do |
| Python | do | do | do |
| Go | do | do | do |
| C# | do | do | do |
| Java | do | do | do |
| Swift | do | do | do |
| OCaml | do | do | do |
| Haskell | do | do | do |
| JS | do | do | do |
| C floor | do, the TX record with the bytes' content id | do, the hand-written numbers held by check-symbol-parity | do |

No language has a reason to defer any of the three.

## §5: The scenes, the server and the gates

One app under five scripts, the task manager's shape (one example, several
scripts through `HAND_QUEUED`), one script per Y11 screen, each the review
capture's leg: `tools/scenes/music_<screen>.steps` for `home`, `playlist`,
`header` (the gradient, in both appearances), `dock` (play, pause, next,
the session, the slider) and `artist`, plus `search`. Each reads the screen
off the platform through verbs that exist: `expect_image_phase`,
`expect_shape`, `expect_ground`, `expect_tint`, `expect_selected`,
`expect_dock`, `hover`, `expect_rows`, the player's state read through the
labels the app's handlers write (tools/scenes/media_session.steps' shape),
`expect_now_playing`, `session_send` for next and previous and `ax_action`
for the dock's buttons (the media session scene's verbs), `expect_toast`.
Two reads each new gap needs: the session's artwork read back off the
system's Now Playing where the platform lets a reader see it (to be
measured: MPNowPlayingInfoCenter's artwork, MPRIS's `mpris:artUrl`, the
SMTC's thumbnail, media3's metadata), and the formatter's string in the
format scene.

The server: the `catalogue` family with its query-routed addresses and the
JSON type; the lanes start it for the `music_` legs through
`media_server.serves` (its `SERVED` tuple grows; tools/lib/netimage_server_routes.py
holds every lane to that one predicate).

Gates that grow (each with watched negatives, counts printed):
- check-assets: the family's README and ATTRIBUTION, the census in
  tools/scenes/assets.steps, and the generator's `--check`, which also
  refuses any track or album outside CC BY and CC BY-SA. Its negative: one
  snapshot entry's licence doctored to BY-NC in a copy, watched refused.
- check-symbols and check-symbol-parity: the ten symbols.
- check-sugar-surface: artwork bytes and the duration formatter in all nine.
- check-slider-commit: M10's hold per backend, the held write applied at the
  gesture's end; a cut that applies the write at once is watched red.
- check-verbs (skin_routes): the macOS native table's double-click action
  and its selection, the Y4 rule that was never wired.
- check-staging: the Python app's file in both phone hosts' staged lists.

### M14: The dock's layout, volume and previous (RULED 2026-10-18)

The maintainer, 2026-10-18, on the dock's review page: the dock's transport
is centred on the window as Spotify's is, the track's art and lines in a left
zone and the heart and volume in a right zone of EQUAL width, so the middle
stays centred whatever the title's length; the phone sheet's transport row is
centred the same way. The dock carries a VOLUME slider ("yeah we definitely
want a volume slider"). PREVIOUS restarts the playing track when it has played
more than about three seconds and goes to the previous track otherwise ("we
should probably restart the track after three seconds").

### M15: The album header's gradient (RULED 2026-10-18: B)

The maintainer, 2026-10-18: the inset gradient "looks a bit tacky", maybe the
wrong colours, maybe darker and subtler, maybe full bleed (the inset leaves a
border around it), maybe a solid colour. To be ruled from a comparison page
showing, on several real covers in light and dark: (A) the current inset
gradient; (B) full bleed, the cover's most vivid colour darkened and muted, a
long soft fade into the page; (C) full bleed, a solid muted colour.

RULED 2026-10-18 from the comparison page (the maintainer: "I think B looks
best"): B, full bleed, the cover's most vivid colour darkened to a deep wash
in dark and lifted to a pale tint in light, fading into the page; and "B's
bottom can be slightly lower": the coloured area runs down until the gap
between its edge and the track table equals the table's side margin. The
vivid pick needs the cover's main colours, which kaya does not report
(image_dominant answers the most common one); whether to add an
image_palette beside it is asked separately. RULED 2026-10-18 (the
maintainer: "definitely yes to image_palette"): kaya adds image_palette beside
image_dominant, the picture's main colours with their shares, in the core and
all nine bindings and the C floor; the header picks the most vivid colour with
enough share.

RULED 2026-10-18 from the vivid-header review page (the maintainer: "for the
questions, i agree with everything"): (1) the core's light-mode clamp lifts a
data colour's lightness while KEEPING its chroma (a pale rose, not a grey), as
Y2's text already says it does, for every app; (2) the album header's line
under the title no longer repeats the artist, whose name is the link to the
artist page; (3) the vivid pick's share threshold is lowered so a small vivid
figure (The Banquet's yellow, 1.6% of its cover) counts; (4) a picture ground at
the top of a phone screen, outside a scroll, runs under the status bar as a
gradient ground does (safe-area A3), on both phones. The fade line at the header's
edge and the Mac's colour stopping under the title bar stay as they are.
BUILT 2026-10-18: `image_palette(bytes, n)` in crates/kaya/src/dominant.rs
(at most n and at most 16 colours, each with its share, largest first; a
greedy squared-error cut of a 2^15-bin histogram in integer arithmetic, so
every platform answers the same bits), the C ABI's `kaya_image_palette`, and
all nine bindings' spellings, held by the skin census. guests/python/music.py's
`header_colour` takes the palette entry with the highest chroma times the root
of its share among those over 2% of the picture, between L* 8 and 96 and at
chroma 15 or more, and the dominant colour when none qualifies. The dark wash
now matches the comparison's B on all four covers. In light the header is
still a near grey (C0BABB on Through The Olive Branches, BBBCB8 on This
Painted Life): the core's light clamp lifts L* 30 to 75 by mixing with white,
which drops the chroma Y2 says it keeps. BUILT 2026-10-18, the four rulings:
(1) crates/kaya/src/brand.rs's light clamp lifts L* at the seed's Oklab hue and
chroma, giving chroma up only where the sRGB gamut ends (673946 lifts to E3ABB9
where the mix gave C1B8BA), held by brand::tests'
the_light_top_keeps_the_seeds_hue_and_chroma and skin_routes' light-clamp
clause; (2) `album_about` reads "2021 · 2 songs, 0:40"; (3) VIVID_SHARE is 1%,
so The Banquet's gold figure (D2B257, 1.6%) is its seed; (4) an image ground
first in a window giving no inset runs under the status bar on both phones,
the bars' icons taking the shade that reads on the picture's strip, the
grounds scene's hero being the case (tools/lib/safearea_routes.py, the grounds
phone tails).

### M16: The review round of 2026-10-20 (RULED 2026-10-20)

The maintainer accepted these as recommended ("I'm okay with all rulings except
the tests/matrix ones"):

Cards: (1) a card fills its grid column and every card in a row takes the
tallest's height, tops aligned, on every platform; (2) a label gains a maximum
line count in the core and all nine bindings, cards two lines, the dock one;
(3) a hidden section takes no space; (4) iOS's selected card uses the stronger
selected fill; (5) the artist page's albums drop their outer card on iOS.
Tables: (6) a two-line title cell is centred on its art; (7) the macOS table
sizes "#" to its content and draws no filler stripes; (8) Android's selected
row covers the number. Navigation: (9) a pushed screen in a two-pane window
shows its back button; (10) an Android pushed page shows the top app bar with
back; (11) iOS drops the repeated uppercase album name; (12) no third pane for
now; (13) the artist page opens at once with a loading state. Dock and player:
(14) repeat is a lit toggle that swaps to the repeat-one symbol; (15) Android's
lit toggle takes a tinted background; (16) a muted-volume symbol; (17) a slider
takes a maximum width; (18) no volume on phones; (19) the phone dock opens the
player from its art and title only; (20) the toast shows above an open sheet;
(21) a button's symbol is settable from a template in all nine bindings; (22)
dark dock legs. Header: (23) an album's total in "1 hr 12 min" style, a
track's in "3:45"; (24) favourites persist, cleared under the harness; (25) the
600 px artist picture where the snapshot has one. iOS: (26) keep the status
bar style hook, with a check that refuses loudly if its method is not found;
(27) a screen whose top is a picture uses the inline title. Bindings: (28)
Python and JS can add children to a built container; (29) a symbol on a
stamped row in Python, the others checked; (30) the bindings' default image
fetch sends "kaya/<version>" as its User-Agent; (31) G8's WinUI amendment
confirmed: SelectorBar items keep their natural widths.
Refused: (32) no refusal to start on battery (the maintainer handles power);
(33) the linux lane's ceiling keeps the container's core rebuild ("forces us to
get a feel for the real inner loop"); (36) no driver-side bypass of XCTest's
animations-idle wait; the cause stays under investigation. Then also accepted (the maintainer:
"I'm okay with 34 and 35", and on 36 "I agree to keep watching it"): (34) a
harness verb that fails a label drawn underneath a neighbour; (35) a reader of
a gradient ground's actual top colour, so a header back on the neutral
placeholder fails a scene.

### M17: The phone dock's progress line (RULED 2026-10-21)

From the review page of 2026-10-21: Android's dock and navigation bar read as
one surface (YouTube Music's layout, docs/styling-pass-plan.md Y8), and YouTube
Music marks the player's edge with a thin progress line. The maintainer ruled
the line on Android ONLY ("it goes with the pattern of using native visuals"),
and that the platform decides it, not the app. An app cannot ask which
platform it runs on (bindings/python/kaya/__init__.py, `Platform`), so the app
states the fact and each backend draws its own idiom: the dock names the
player it shows (a dock's `player`, in the core and all nine bindings); the
Compose arm draws a full-width determinate line at the dock's bottom edge,
between the player and the navigation bar, from its own player's position; macOS, iOS, GTK and WinUI keep the association and
draw nothing, since Apple Music's mini player has no line and the desktop
docks carry a scrubber. Controls bound to a player are a separate question
(docs/deferred.md, controls bound to a player).

Built 2026-10-21: `set_dock_player { dock, player }` (TX 86, apply 74), the
root refusing a dock not attached or a player not live and detaching the dock
when its player is released; the spelling in the nine bindings and the C floor
(tools/lib/skin_surface.py's `docked player` rows), every dock guest naming a
player. Compose draws Material's LinearProgressIndicator 2 dp tall across the
dock's bottom edge (above the system inset when no navigation bar is below), flat (no gap, no stop dot, butt caps), from its own media3
player's position each frame while it plays, and keeps it out of the
accessibility tree, since the full player's slider is the position's control
and the line would otherwise be a stop before the dock's buttons.
`expect_dock_player` reads the backend's association in every shared dock
scene; `expect_dock_line` reads the drawn fraction in the Android lane's
music_dock extras and `none` in the iOS one (tools/lib/skin_compose.py holds
the arm).

Amended 2026-10-21 after the review page: the line was first built on the
dock's top edge, which divides the page from the player, while the review's
complaint was the player and the navigation bar reading as one surface. The
maintainer chose to move the same line to the bottom edge, where it is both
the division and the progress.

### M18: The phone docks' height (RULED 2026-10-21)

The maintainer, 2026-10-21, on the dock line's review page: "The player bar
itself looks way too thick [on Android]. The top and bottom padding look
excessive compared to the size of the album art and title inside. On the
flipside, the iOS player bar has zero padding around the album art and it
looks way too thin." Asked to match the platforms' own music apps.

Measured before: Android's dock was 104 dp, the 48 dp art with 28 dp above
and below, of which 16 was the app's `dock_bar` inset and 12 kaya's default
inset for an activatable container (the `dock_open` row, which sets none), so
its press surface does not run flush. iOS 26's tab accessory is a capsule the
platform holds at 48 pt whatever its content asks; the same content overflowed
it, so the 48 pt art filled it edge to edge, 38 pt in from its left end (the
accessory's own 12, the app's 16 and the default 10).

The app may not ask which platform it runs on, so the dock's vertical rhythm
is each phone backend's, the way the line is (M17): inside a phone dock a
container pads its sides only, by its own inset or none (kaya's default inset
for an activatable or filled container is not taken there), and the bar sets
the space above and below. Android pads the bar 8 dp above and below its
content, the progress line under that, so the bar is 64 dp with the 48 dp art
centred (YouTube Music's mini player is about 64 dp; Spotify's 56 dp with 40 dp
art). iOS's accessory pads 8 pt above and below, adds no side padding of its
own, and caps a picture at 32 pt (Apple Music's mini player); the app's 48 is a
maximum, so the art shrinks. Its corners stay kaya's rounded shape: a corner
concentric with the 48 pt capsule at an 8 pt inset is a 16 pt radius, which on
32 pt art is a circle, where Apple Music's art is a rounded square, and
`expect_shape image@dock_art rounded` is a shared step. The art sits 16 from
the bar's leading edge on both phones, the app's inset. The desktops (mac, GTK,
WinUI) and iOS's dock without a tab bar are unchanged.

`expect_dock_height` reads the bar's height less any system inset and
progress line in the phone lanes' music_dock extras (64 on Android, 48 on iOS,
beside `expect_image_size image@dock_art` at 48x48 and 32x32); GTK and WinUI
answer that they do not read it. tools/lib/skin_compose.py and
tools/lib/skin_routes.py hold the two arms. On iOS's accessory the two lines
(about 36 pt) stand taller than the 32 pt art, so the row centres the art on
them and the lines span the row: the iOS lane drops music_dock's
`expect_hugs column@dock_lines` for that leg (tools/lib/lanes/ios.py), which
holds on every other lane.

### M19: The spacing pass (RULED 2026-10-21)

The maintainer, 2026-10-21, on the dock height's review page: "On iOS, in the
table containing a song list, the grey highlight on a row, notice how the left
side of the grey is hugging the "1" with zero space? I have a feeling that
there is a lack of padding there, and perhaps other places too. Perhaps do a
pass over UI spacing on this app."

The pass recaptured every screen on every lane in both appearances (the audit
and the before and after captures are the session's, published on the review
page) and found four classes, each decided in a backend's lowering, none
in the app's numbers:

- A SELECTED TABLE ROW'S FILL HUGGED ITS CELLS. The iOS synthesized tier
  placed the row's ground at the cells' box, 16 pt inside the card; GTK
  zeroed the row's padding and let the card carry the 12 px, so the
  `:selected` fill started at the first digit; WinUI's row grid carried no
  padding under the card's 12 dip interior; Compose's ground reached 8 dp past
  the cells (M16 (8)) and stopped 8 dp short of the segment. Each platform's
  own list pads its selected surface by its cell padding (UIKit's layout
  margin and Material's list item at 16, libadwaita's boxed-list row and
  Fluent's ListViewItem at 12), so each arm now draws the surface across the
  card's interior and keeps the cells where they were: SwiftUI places the
  ground `kayaTableCardInsetX` outside the layout's box on both sides and the
  card clips its corners; GTK takes the head, body and divider out to the
  card's stroke with a negative margin and puts the 12 px back as padding on
  the header, the content box and every row (the trap "A GTK table card is
  paint, never box" is why the cells may not move); WinUI does the same with
  the host, head and rule and `table_row_padding`; Compose's `groundOut` is
  the whole interior. The mac's native NSTableView draws AppKit's own inset
  selection and is untouched.
- A TABLE'S CELLS SAT AT THE ROW'S TOP on both phones ("4" at the top edge
  of a 40 pt art row), while GTK, WinUI and AppKit centre theirs. Both
  synthesized layouts centre every cell on its row now.
- THE ARTIST PAGE'S OVERLAY PANEL HUGGED ITS TEXT ON GTK: the inset's
  transparent border was applied, but libadwaita's `.osd` rule clips the
  background to the padding box (docs/traps.md, the overlay panel that hugged
  its text), so `.kaya-filled.osd` paints its background to the border box.
- A SEARCH SHELF'S CARDS TAKE THEIR TITLES' WIDTH on all five, since a
  sideways shelf's column hugs its content and a label never wraps on its
  own. NOT FIXED: `max_width` is legal on images and sliders only
  (crates/kaya/src/scene.rs, check_prop), so the app cannot bound a card's
  label, and a collection cannot be a grid (M12); the cards' titles take
  `max_lines=2` (M16 (2)) and the width is left to the maintainer, since
  bounding a label or a container is a core prop. The Home cards' titles take
  two lines too.

- (G) ON THE DESKTOPS THE SELECTED FILL TOUCHED THE ART TOP AND BOTTOM (the
  maintainer, 2026-10-21, on the first after-captures: "on desktop, there is
  no vertical space between the album art thumbnail and the grey highlight of
  a row"): GTK's and WinUI's table rows carried no vertical padding, so the
  40 px art filled the row. libadwaita's `row > box.header` is 50 px at
  minimum, 5 px above and below a 40 px picture, and Fluent's list item keeps
  its picture off the fill (the WinUI gallery's 6), so a GTK table row pads
  5 px above and below (TINT_CSS and TABLE_CSS, `TABLE_ROW_PAD_Y`) and a
  WinUI row 6 (`table_row_thickness`), every kaya table, cells unmoved
  sideways. AppKit's native table and both phones already leave room (the
  phones' ground reaches the row gap's half past the tallest cell).

Two verbs read the first two classes in every shared table scene, since no
existing reader could see either (every table observable answers identically
with the fill flush or the cells at the top): `expect_row_inset <row>` passes
when the row's selection surface clears its first and last cells by at least
the backend's own cell padding and, since G, its tallest cell above and below
by the backend's vertical room (GTK's 5, WinUI's 6, two on the phones;
AppKit's own on the native tier, where the cells are the table's rows and any
clearance is the platform's), and `expect_row_centered <row>` when every
cell's centre is within two units of the row's. tools/scenes/music_header.steps,
music_artist.steps and tracks.steps read both after the selection; the
readers and the arms are held by tools/lib/skin_routes.py, skin_compose.py,
skin_gtk.py and skin_winui.py in check-verbs, each cut watched red.

Left to the maintainer, since the platforms disagree or the number is the
app's: the search shelf's card widths above; the plain-role artist link under the album title sits 17 px (GTK's
text-button padding), 12 dp (Material's text button) and 11 px (Fluent's
subtle button) right of the title on the three backends whose plain button
carries padding, while SwiftUI's plain style has none; the sidebar's heading
at the sidebar's inset beside rows whose text sits 10-12 further in; and the
album header's 24 against the page's 16.

### M20: The spacing pass's open questions (RULED 2026-10-21)

The maintainer accepted the recommendations on the spacing page ("im okay with
your recommendations"): (1) the `plain` role's label lines up with the text
around it on GTK, Compose and WinUI (each arm takes back its own padding, as
WinUI's `link` role already does), which moves every plain button in every
kaya app; (2) a label and the containers take a maximum width in the core and
all nine bindings, and the app caps the search shelf's cards at the art's
width with two lines; (3) the WinUI artist panel that wraps its stats line
instead of growing to fit it is a bug in that backend's flex widths, fixed;
(4) the album header keeps its 24 inset; (5) the sidebar's "Your Library"
heading stays at the sidebar's inset.

### M21: Cards in a row are the same height (RULED 2026-10-21)

After M20 (2) gave the search shelf's titles three lines, the two David Amber
cards read as different heights (Vol. 2's title takes one more line than
Vol. 1's). The maintainer: "no uneven cards". The rule: every card in one row
takes the row's tallest card's height, with the card's ground reaching the
bottom and its content top-aligned.

Where it belongs: two backends, no app change. The rule is already kaya's, the
2026-08-22 breadth ruling (docs/layout-knobs-plan.md §1, DESIGN.md Layout): a
nested crossing container spans its parent's breadth under every align mode,
so a column stamped into a sideways row is the row's height, and the Home and
artist grids were even on all five since a grid cell spans and `card()` fills
it. Read from the pictures' pixels rather than by eye (the eye called the mac
and Windows uneven; both grounds end on one row there), only GTK and Compose
drew the shelf uneven, one class of bug on both: a For's host is lowered as a
column kind and the app's `axis` lays it sideways (docs/adaptive-layout-plan.md
D1, the axis is the arrangement truth), and each arm's cross placement read
the KIND. GTK wrote its axis key (container_vertical) only at creation, so
crosses_container read the stamped column as a column in a column and the
Align arms and add_child keyed halign on the kind; the Prop::Axis arm writes
the key now and the two Align arms and add_child read it. Compose's
kayaHugCross keyed `crossVertical` on KIND_ROW, so the sideways host was never
pinned to `height(IntrinsicSize.Min)` and the cards' fillMaxHeight resolved
against the horizontal scroll's unbounded height; it reads the axis now.
tools/lib/skin_gtk.py and skin_compose.py hold both arms with a cut each
watched red in check-verbs. An app's `align("stretch")` on the shelf's
container was tried first and changed no backend's picture, so it is not
written: a declaration of the default misleads the next reader.

Read by `expect_same_height <a> <b>` (two columns', rows' or labels' laid-out
heights within a point): GTK's and WinUI's window_frame, Compose's
kayaInsetOuter, and on SwiftUI the skin anchor's view (the drawn box, outside
the filled surface) before kayaNodeFrames, since a flex child's node frame is
its TRACK, the row's full height whatever the card drew, and read first it
passes two uneven cards. music_search.steps and both phone search tails read
it on the two album cards, music_home.steps on the Jazz row's two cards and
music_artist.steps on Kellee Maize's two albums, each pair of different
content heights on at least one lane; the verb read "227 tall, 208 tall" on
GTK and "216 tall, 200 tall" on Compose before the fixes. check-verbs holds
the verb in all three harnesses.

### M22: The final review's fixes (RULED 2026-10-23)

The maintainer's rulings on the final review's pictures, each built as its
own change.

(1) "The faint colors should be fixed for hover." Measured off the review's
pictures as a CIELAB lightness step between a hovered card's ground and a
resting one: WinUI's PointerOver, the reference for visible, 3.1 (253 to
244); the mac's quaternarySystemFill over the card's secondarySystemFill,
2.1 (219 to 213); GTK's libadwaita `.card.activatable` hover (3% of the
card's foreground), 2.1 (255 to 249, the window's own ground). The mac now
lays `secondarySystemFill` over the hovered container, the card's own fill
laid once more (AppKit has no hovered-surface colour; the system fills are
its ladder of grounds, and the next step up from a card is a second layer of
the same one): 219 to 202 light, 61 to 76 dark. GTK takes libadwaita's own
`$hover_color` and `$active_color` (7% and 16% of currentColor, what it
paints on a hovered and pressed activatable row and a flat button,
_colors.scss) on cards as on rows: 255 to 241 light, 51 to 65 dark. WinUI is
untouched. Compose keeps Material's 8% onSurface hover layer, which a phone
draws only under a mouse; the lanes' phones have no pointer and cut at the
first hover. The floor is `expect_fill ... hovered` itself: a reading whose
nearest surface is the hover answers `faint` when it stands less than 3.0
in lightness from the resting ground under it (crates/kaya/src/harness.rs
HOVER_MIN_LIGHTNESS and faint_hover, copied into the SwiftUI and Compose
readers and held equal by check-verbs); the old colours read "faint (a
hover, sampled D4D4D4 against its resting D9D9D9: a lightness step of 2.0
...)" on the mac and "F9F9F9 against FFFFFF ... 2.1" on GTK. A hovered bare
row on the mac now draws the colour a resting card draws.

## §6: Build order

1. The measurements §7 marks for the depth: Jamendo's extensionless MP3 on
   all five players (by hand, against the mirror once it exists, and
   against Jamendo with the maintainer's id); embedded CPython's https on
   both phones; the slider under a held pointer per backend; the gap between
   two tracks per backend; the Now Playing artwork readers; the ten glyphs at
   each platform's floor.
2. ~~The defect: the macOS native table's double-click and selection (Y4).~~ Fixed 2026-10-17 (§0's playlist row).
3. ~~The snapshot: the generator, run once by the maintainer with his id, the
   family committed with its README and ATTRIBUTION, the server's routes.~~
   Built 2026-10-17: tools/gen-catalogue.py (run once with the maintainer's
   id, 37 API calls) wrote guests/assets/catalogue (27 files, 3,269,776
   bytes: twelve 20 s clips, six covers at 300 and 600 px, `api.json` with
   24 answers, README.md and ATTRIBUTION.md; the artist images are album
   covers, M2); Pierce Murphy (jazz), Kellee Maize (electronic) and David
   Amber (rock), every track CC BY 3.0 or CC BY-SA 3.0. tools/lib/catalogue.py
   is the one resolver the server and `--check` share; the routes are held by
   tools/lib/catalogue_server_routes.py (check-exclusive) and the snapshot by
   check-assets' C14. No Jamendo playlist is in it: a public playlist's tracks
   are any licence and any artist, so its answer narrowed to the twelve is
   empty; the demo's playlists are the user's own.
4. The gaps as ruled, depth then breadth: M8's symbols, M9's formatter, M7's
   artwork, M10's hold, each on the mac and iOS with Rust, then the other
   backends and bindings.
5. The app, screen by screen in Y11's order, each screen's scene green on the
   mac and then on the other four lanes, each a review capture as it is
   built: the library sidebar and Home, the playlist table, the gradient
   header, the dock with the session and media keys, the artist page, then
   search and the toasts.
   BUILT so far: the library sidebar and Home (6a0fb1bf,
   tools/scenes/music_home.steps), the playlist table (e115ba33,
   music_playlist.steps), and the gradient header (2026-10-18,
   music_header.steps, light and dark on every lane): the 600 px cover's
   `image_dominant` computed by the app on its loader thread, a neutral grey
   until the cover decodes, the title as a heading, "Artist · Year · N songs,
   M:SS" with the total through the duration formatter, Play from the
   album's first track, and the favourite heart (the toggle role) kept by
   the app in memory; `expect_checked` reads the heart off each platform's
   accessibility tree.
   The dock with the session and media keys (2026-10-18,
   music_dock.steps): attached by the first play, the rounded art and two
   lines, shuffle (the toggle role), previous, play or pause (its symbol and
   name following the player's state), next, repeat (a button cycling off,
   all and one, its symbol swapped by the app), the scrubber with elapsed and
   remaining time held under a gesture (M10), and the playing track's heart;
   on the phones the dock holds the art, the lines, play and next, and its
   art-and-lines row opens the full player as a sheet at the large detent.
   The app's queue (M11) answers next and previous from the dock and through
   the session, declared with the album cover's bytes (M7); `expect_symbol`
   reads a button's glyph on each platform. The desktops' third pane is not
   built, by the maintainer's choice in M16 (12), "no third pane for now".
   Search and the toasts (2026-10-19, music_search.steps): a Search row in
   the desktops' sidebar and a Search section on the phones; the platform
   search field asks the catalogue's three searches (albums and artists by
   name, tracks by text) once the user pauses for 300 ms, a later answer
   replacing an earlier one; the segmented control (All, Albums, Artists,
   Tracks) narrows the answer as a diff of each kind's rows; albums and
   artists as sideways shelves of cards (an artist's round), tracks as a list
   of rows that play on activation; a line under the control says the counts,
   the empty state, or "No results for …". The heart says "Added to Liked
   Songs" or "Removed from Liked Songs" in a toast whose Undo is the window's
   undo of that step (docs/toast-plan.md T4); a search that fails says
   "Couldn't reach the catalogue" with Retry. The snapshot holds the scene's
   two searches (tools/gen-catalogue.py `SCENE_SEARCHES`, `--add-searches`).
6. The matrix once, then the review page: every lane's capture of every
   screen in light and dark, a card hovered on the desktops and selected,
   the playing row's tinted title, the dock on the desktops and above the tab
   bar on the phones with the phone's sheet open, the system's Now Playing
   with the album's art on each platform, and the app by hand against
   Jamendo on the mac. That page also closes N17 and the styling pass's §6
   step 5.

## §7: Measured, and to be measured

- MEASURED 2026-10-17 from the desk: §0's catalogue table. Jamendo's API
  needs a client id on every call and every id found in public is invalid,
  suspended or over its limit; its storage host serves `mp31` as constant
  96 kbps MPEG-1 Layer III at 44.1 kHz (a 272 s track: 3,291,136 bytes, the
  first frame after a 26 KB ID3 tag) and `mp32` at about 198 kbps average
  (6,735,872 bytes), both answering a Range request with 206 over https with
  no redirect in 1.9 to 2.2 s; its image host answers a 300 px cover in
  12,502 bytes and a 600 px one in 35,177 bytes (JPEG), one album's in GIF at
  every width, an artist image at 500 px in 18,421 bytes, with no key and no
  redirect. Openverse's anonymous limits are 20 a minute and 200 a day with
  20 results a page; ten CC BY or BY-SA jazz results are 18,049 bytes in
  2.0 s, all from Jamendo.
- COMPUTED 2026-10-17: a 20 s clip at 96 kbps is 240 KB; twelve are about
  2.9 MB; twelve 300 px and six 600 px covers and three 500 px artist images
  about 0.8 MB at the measured sizes. The asset root today is under 1 MB of
  media (guests/assets/media 896 KB, guests/assets/covers 36 KB).
- READ FROM THE TREE 2026-10-17 at b2a5d252: §0's table, with the file and
  line for each gap.
- MEASURED 2026-10-17, the extensionless address: the mac's AVPlayer
  (the SwiftUI interpreter through the harness, a scratch Python guest) played
  the mirror's `/catalogue/storage/?trackid=1860165&format=mp31` past 1 s with
  a 20 s duration, and Jamendo's live
  `https://prod-1.storage.jamendo.com/?trackid=1860165&format=mp31` (no id
  needed) past 1 s with its 249 s; GStreamer's playbin3 in the linux image
  (gst-launch with fake sinks, the element the GTK arm uses, not the arm
  itself) played the mirror's address to EOS with no error; the Windows VM's
  Windows.Media.Playback.MediaPlayer (the WinUI arm's player, from PowerShell,
  not the arm itself) played it with a 20.062 s duration and its position
  advancing. Jamendo's API answers a populated query with no results
  intermittently (one artist's `tracks?artist_id=` answered 0, 18, 0 results
  on three asks seconds apart), so the generator asks an empty answer again.
- To be measured at the depth: iOS's and Android's players on Jamendo's
  extensionless address; embedded CPython's certificate verification on iOS and Android;
  the slider's thumb under a held pointer while the app writes, per backend;
  the silence between two tracks when the app swaps `source` on `ended`, per
  backend; which Now Playing readers can see artwork; the ten glyphs against
  each platform's installed set and floor (check-symbols holds SF's); the
  context menu on a macOS native table row; whether a Python host bundle
  carrying the `audio` background mode for one scene changes any other
  Python leg.

## §8: What the maintainer is asked

Every ruling above is his. These need something only he can supply:

1. M1, the catalogue: Jamendo's own API with the person's own free client id
   and a bundled sampler when there is none (recommended); or Openverse,
   keyless; or the Internet Archive; or Audius. And whether Jamendo's terms
   (the cache and offline clause, the look-and-feel clause) read to him as
   §2 M1 reads them.
2. M2, the lanes: a 12-clip CC BY / BY-SA snapshot of Jamendo served by the
   lane's media server at Jamendo-shaped addresses (recommended, about
   3.7 MB in the asset root), or synthetic tones and covers, or whole tracks.
   And the generator run once with his own client id, since nobody else may
   hold one for the repository.
3. M3, the language: Python (recommended), Go, Rust, or a new language on
   fewer than five lanes.
4. M4, sign-in: none, the client id in a secure field, autofill left to the
   password manager demo (recommended); or Jamendo Connect with the web
   authentication session and the secure store built first.
5. M6, the window: three panes on the desktops (recommended) or two.
6. The gaps, each a build: M7 artwork from bytes, M8 the ten transport
   symbols, M9 the positional duration formatter, M10 the slider holding an
   app's write during a gesture (each recommended), and M12's deferral of a
   collection laid out as a grid (recommended) against building it now.
7. M11: the queue in the app with gapless and preload deferred
   (recommended).

M5 (the appearance follows the system, both on the review page) is carried
from Y11 and not asked again; M13 applies rulings already made.
