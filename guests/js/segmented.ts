// The segmented control scene (tools/scenes/segmented.steps;
// docs/segmented-plan.md §5).

import * as kaya from "kaya-gui";

const Habit = kaya.record({ name: String, cadence: Number }, "Habit");

const PERIODS = ["Day", "Week", "Month"];
const VIEWS = [["Info", kaya.Symbol.INFO], ["Edit", kaya.Symbol.EDIT]] as const;
const CADENCES = ["Daily", "Weekly"];

const app = new kaya.App();
let heard = 0;

function onPeriod(index: number): void {
  heard += 1;
  period.set(index);
  periodText.set(`period: ${PERIODS[index]}`);
  heardText.set(`heard: ${heard}`);
}

function onReset(): void {
  period.set(0);
  periodText.set("period: Day");
}

function onView(index: number): void {
  viewText.set(`view: ${VIEWS[index]![0]}`);
}

function onCadence(row: kaya.RowHandle<kaya.Fields<typeof Habit.schema>>, index: number): void {
  cadenceText.set(`cadence ${String(row.key)}: ${CADENCES[index]}`);
}

const { period, periodText, heardText, viewText, cadenceText } = app.window({ title: "segmented" }, () => {
  const period = kaya.signal(0);
  const periodText = kaya.signal("period: Day");
  const heardText = kaya.signal("heard: 0");
  const viewText = kaya.signal("view: Edit");
  const cadenceText = kaya.signal("cadence: -");
  const habits = kaya.collection(Habit);
  kaya.column(() => {
    kaya.segmented(PERIODS, { selected: period, onSelect: onPeriod }).a11yId("period").a11yLabel("Period");
    kaya.label({ bind: periodText });
    kaya.label({ bind: heardText });
    kaya.button("Reset", { onClick: onReset }).a11yId("reset");
    kaya.segmentedSymbols(VIEWS, { selected: 1, onSelect: onView }).a11yId("view").a11yLabel("View");
    kaya.label({ bind: viewText });
    kaya.label({ bind: cadenceText });
    for (const habit of habits) {
      kaya.label({ bind: habit.name });
      kaya.segmented(CADENCES, { selected: habit.cadence, onSelect: onCadence }).a11yId("cadence");
    }
  });
  habits.insert("read", Habit({ name: "read", cadence: 1 }));
  habits.insert("walk", Habit({ name: "walk", cadence: 0 }));
  return { period, periodText, heardText, viewText, cadenceText };
});

app.run();
