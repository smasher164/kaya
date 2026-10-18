// The tracks scene (tools/scenes/tracks.steps; docs/styling-pass-plan.md Y5,
// Y6, Y7): a playlist's table whose title cell is rounded art beside the
// track's name over its artist, the playing track's name in the accent, and a
// row the app selects when the user picks it and names when it is activated
// (Y4). See guests/rust/tracks.rs.

import * as kaya from "kaya-gui";

const Track = kaya.record({ number: String, title: String, artist: String, album: String, art: Uint8Array, tint: kaya.Tint, selected: Boolean }, "Track");

const PLAYLIST = 60;
const PLAYING = 3;
const NAMES = [["Blue in Green", "Miles Davis", "Kind of Blue"], ["So What", "Miles Davis", "Kind of Blue"], ["Naima", "John Coltrane", "Giant Steps"]] as const;

const app = new kaya.App();
const art = kaya.asset("covers/cover-600.jpg").bytes();

function table(tracks: kaya.Collection<kaya.Fields<typeof Track.schema>, kaya.Row<typeof Track.schema>>, id: string, rowId: string, grow?: number): void {
  for (const track of tracks.columns(["#", "Title", "Album"], { a11yId: id, ...(grow === undefined ? {} : { grow }) })) {
    kaya.row({ selected: track.selected, onSelect: onPick, onActivate: onPlay }, (line) => {
      line.a11yId(rowId);
      kaya.label({ bind: track.number });
      kaya.row(() => {
        kaya.image(track.art, { fit: "cover", shape: "rounded" }).maxWidth(40).maxHeight(40).a11yId("art");
        kaya.column(() => {
          kaya.label({ bind: track.title, tint: track.tint }).a11yId("name");
          kaya.caption({ bind: track.artist });
        });
      });
      kaya.label({ bind: track.album });
    });
  }
}

function onPick(row: kaya.RowHandle<kaya.Fields<typeof Track.schema>>): void {
  picked.set(`picked: ${row.key}`);
  select(row.key);
}

function onPlay(row: kaya.RowHandle<kaya.Fields<typeof Track.schema>>): void {
  played.set(`played: ${row.key}`);
  select(row.key);
}

function select(key: kaya.Key): void {
  for (let i = 0; i < NAMES.length; i++) album.patch(`a${i + 1}`, { selected: `a${i + 1}` === key });
  for (let i = 0; i < PLAYLIST; i++) playlist.patch(`t${i + 1}`, { selected: `t${i + 1}` === key });
}

function track(i: number): kaya.Fields<typeof Track.schema> {
  const [title, artist, album] = NAMES[i % NAMES.length]!;
  return Track({ number: String(i + 1), title, artist, album, art, tint: i + 1 === PLAYING ? kaya.Tint.ACCENT : kaya.Tint.NONE, selected: false });
}

const { album, playlist, picked, played } = app.window({ title: "tracks", width: 720, height: 640 }, () => {
  const album = kaya.collection(Track);
  const playlist = kaya.collection(Track);
  const picked = kaya.signal("picked: none");
  const played = kaya.signal("played: none");
  kaya.column({ spacing: 12 }, () => {
    kaya.label({ bind: picked }).a11yId("picked");
    kaya.label({ bind: played }).a11yId("played");
    table(album, "album", "a");
    table(playlist, "tracks", "t", 1);
  });
  for (let i = 0; i < NAMES.length; i++) album.insert(`a${i + 1}`, track(i));
  for (let i = 0; i < PLAYLIST; i++) playlist.insert(`t${i + 1}`, track(i));
  return { album, playlist, picked, played };
});

app.run();
