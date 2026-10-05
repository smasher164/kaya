import * as kaya from "kaya-gui";

const Line = kaya.record({ qty: Number }, "Line");
const normal = new kaya.TimecodeRate(25);
const drop = new kaya.TimecodeRate(30000, 1001, true);
const app = new kaya.App();
let commits = 0;
let phase = 0;

const { status, playhead, rowStatus, switching, switchValue } = app.window({ title: "Timecode", width: 440, height: 500 }, () => {
  const status = kaya.signal("commits: 0");
  const rowStatus = kaya.signal("row: none");
  const playhead = kaya.signal(kaya.fmt.timecode(93087, normal));
  const rows = kaya.collection(Line);
  const switchValue = kaya.signal(-2);
  const switching = kaya.column(() => {
    kaya.label("25 fps");
    kaya.label({ bind: playhead }).a11yId("playhead");
    kaya.numberField({ value: 93087, format: kaya.NumberFormat.timecode(normal), onCommit: onCommitted })
      .a11yId("position").a11yLabel("Position");
    kaya.label({ bind: status }).a11yId("commits");
    kaya.label("29.97 drop-frame");
    kaya.numberField({ value: 1799, format: kaya.NumberFormat.timecode(drop), onCommit: onCommitted })
      .a11yId("drop").a11yLabel("Drop frame");
    kaya.entry().a11yId("note");
    for (const line of rows) {
      kaya.numberField({ value: line.qty, format: kaya.NumberFormat.timecode(normal), onCommit: onRow })
        .a11yId("rowtime");
    }
    kaya.label({ bind: rowStatus }).a11yId("row");
    const switching = kaya.numberField({ value: switchValue }).a11yId("switching");
    kaya.button("Switch format", { onClick: switchFormat }).a11yId("switchformat");
    return switching;
  });
  rows.insert("a", Line({ qty: 25 }));
  return { status, playhead, rowStatus, switching, switchValue };
});

function onCommitted(value: number): void {
  commits++;
  status.set(`commits: ${commits}`);
  playhead.set(kaya.fmt.timecode(value, normal));
}
function onRow(row: kaya.RowHandle<kaya.Fields<typeof Line.schema>>, value: number): void {
  rowStatus.set(`row ${String(row.key)}: ${value}`);
}
function switchFormat(): void {
  if (phase === 0) {
    switching.numberFormat(kaya.NumberFormat.timecode(drop));
    switchValue.set(1800);
  } else if (phase === 1) {
    switchValue.set(-2);
    switching.numberFormat(kaya.NumberFormat.number);
  } else if (phase === 2) {
    switchValue.set(1800);
    switching.numberFormat(kaya.NumberFormat.timecode(drop));
  } else {
    switching.numberFormat(kaya.NumberFormat.number);
    switchValue.set(-2);
  }
  phase = (phase + 1) % 4;
}
app.run();
