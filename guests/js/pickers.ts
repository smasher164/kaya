// The pickers scene (tools/scenes/pickers.steps; docs/datetime-plan.md).
//     KAYA_SELFTEST=pickers node guests/js/pickers.ts

import * as kaya from "kaya-gui";

const Task = kaya.record({ name: String, due: kaya.CivilDate }, "Task");

const app = new kaya.App();

function day(d: kaya.CivilDate): string {
  return `${String(d.year).padStart(4, "0")}-${String(d.month).padStart(2, "0")}-${String(d.day).padStart(2, "0")}`;
}

function clock(t: kaya.CivilTime): string {
  return `${String(t.hour).padStart(2, "0")}:${String(t.minute).padStart(2, "0")}`;
}

let dateText!: kaya.Signal<string>;
let timeText!: kaya.Signal<string>;
let rowText!: kaya.Signal<string>;
let dateSig!: kaya.Signal<kaya.CivilDate>;
let timeSig!: kaya.Signal<kaya.CivilTime>;

function onDate(picked: kaya.CivilDate): void {
  dateText.set(`date: ${day(picked)}`);
}

function onTime(picked: kaya.CivilTime): void {
  timeText.set(`time: ${clock(picked)}`);
}

function onRowDate(row: kaya.RowHandle<kaya.Fields<typeof Task.schema>>, picked: kaya.CivilDate): void {
  rowText.set(`row ${String(row.key)}: ${day(picked)}`);
}

function onReset(): void {
  dateSig.set({ year: 2026, month: 3, day: 1 });
  timeSig.set({ hour: 9, minute: 0 });
}

app.window({}, () => {
  dateText = kaya.signal("date: none");
  timeText = kaya.signal("time: none");
  rowText = kaya.signal("row: none");
  dateSig = kaya.signal<kaya.CivilDate>({ year: 2026, month: 9, day: 4 });
  timeSig = kaya.signal<kaya.CivilTime>({ hour: 14, minute: 30 });
  const tasks = kaya.collection(Task);
  kaya.column(() => {
    kaya.label({ bind: dateText }); // label#0
    kaya.label({ bind: timeText }); // label#1
    kaya.label({ bind: rowText }); // label#2
    kaya
      .datePicker({ value: dateSig, min: { year: 2026, month: 1, day: 1 }, max: { year: 2026, month: 12, day: 31 }, onChange: onDate })
      .a11yId("when")
      .a11yLabel("Due"); // date_picker#0
    kaya.timePicker({ value: timeSig, step: 15, onChange: onTime }).a11yId("at").a11yLabel("At"); // time_picker#0
    kaya.button("reset", { onClick: onReset }); // button#0
    for (const task of tasks) {
      kaya.label({ bind: task.name });
      kaya.datePicker({ value: task.due, onChange: onRowDate }).a11yId("due");
    }
  });
  tasks.insert("a", Task({ name: "a", due: { year: 2026, month: 10, day: 1 } }));
  tasks.insert("b", Task({ name: "b", due: { year: 2026, month: 11, day: 20 } }));
});

app.run();
