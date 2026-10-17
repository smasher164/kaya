# catalogue — a Jamendo snapshot (docs/media-player-plan.md M2)

What the files are: the lanes' mirror of Jamendo for the media player demo,
served by tools/media-server.py at addresses shaped like Jamendo's through
tools/lib/catalogue.py:

- `t<track id>.mp3`: 12 clips, the first 20 s of each track's
  `mp31` stream, at `/catalogue/storage/?trackid=<id>&format=mp31` with no
  file extension, as Jamendo's own storage address has none.
- `album-<id>-<width>.jpg` (300 and 600 px): the covers, at
  `/catalogue/usercontent?type=album&id=<id>&width=<width>`. The artist
  image address `/catalogue/usercontent?type=artist&id=<id>&width=<width>`
  answers with the cover of the album `_snapshot.artist_images` names for that
  artist: the first of the artist's albums here whose every track is CC BY
  or CC BY-SA. Jamendo's own artist images carry no licence (one was the
  cover of a BY-NC-ND album), so none is in this snapshot.
- `api.json`: Jamendo's answers to the requests the demo makes, keyed by the
  request with `client_id` and `format` dropped and the parameters sorted,
  served at `/catalogue/v3.0/<endpoint>/?<query>` as `application/json`.
  Each answer is Jamendo's own with the items outside this snapshot removed,
  `headers.next` and `results_count` adjusted, the waveform and download
  fields dropped, durations set to the clips', and every storage and image
  address rewritten to the mirror's relative form. `_snapshot` records the
  selection.
- `ATTRIBUTION.md`: every track's title, artist, album, Jamendo page and
  licence, as CC BY requires.

Where they came from: Jamendo's API v3 (https://api.jamendo.com/v3.0/),
taken 2026-10-17 by tools/gen-catalogue.py with the maintainer's own
client id, which is personal under Jamendo's terms and in no file here.

The selection rule: for each genre in jazz, electronic, rock, Jamendo's
`tracks` chart (`order=popularity_week`, `ccnc=false`, `ccnd=false`) is walked
in order for the first artist not yet chosen who has an artist image address and two
albums whose every track is CC BY or CC BY-SA, with two tracks of at least
20 s each and JPEG covers: the album holding the chart's track
first, then the most recent other. Each album keeps its two tracks highest in
Jamendo's popularity among the artist's own tracks, the chart's track
first, and an artist whose tracks Jamendo will not list by popularity is
passed over (the artist page's top tracks are that list). The searches are
the first artist's name and the first track's title.

The licence: CC BY or CC BY-SA per track, named in ATTRIBUTION.md; the
generator refuses any other, and `--check` refuses a committed answer naming
any other.

To regenerate: `tools/gen-catalogue.py` inside `nix develop` with a Jamendo
client id in `KAYA_JAMENDO_CLIENT_ID` or `~/.config/kaya/jamendo-client-id`
rewrites this directory; commit the result. Jamendo's catalogue moves, so a
regeneration may choose other music. A new or renamed file moves
tools/scenes/assets.steps' frozen census. `tools/gen-catalogue.py --check`
reads only these files (tools/check-assets.py runs it).
