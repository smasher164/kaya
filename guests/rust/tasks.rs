//! The task manager, the third forcing artifact (docs/tasks-plan.md):
//! tools/scenes/tasks.steps. ONE COLLECTION PER LIST, and the row record
//! carries the whole task, so the core's undo restores the model and the
//! app's maps are caches rebuilt from the collections (§1, §3). "Today"
//! is fixed under the harness.

use std::collections::BTreeMap;

use kaya::WindowId;

/// THE APP'S OWN DOCUMENT (docs/tasks-s4-plan.md P1/P7): a SQLite database
/// under `kaya::app_data_dir()`, through rusqlite with the engine compiled
/// in. kaya answers the directory and nothing else — the format is the
/// app's, and this module is the whole of it.
mod store {
    use std::collections::BTreeMap;

    use rusqlite::Connection;

    use super::TaskRow;

    /// Everything that survives a relaunch. `caption` is derived from the
    /// other fields and the project names, so it is not stored.
    #[derive(Clone, Default, PartialEq)]
    pub(super) struct Snapshot {
        pub tasks: BTreeMap<String, TaskRow>,
        pub projects: BTreeMap<String, String>,
        pub order: BTreeMap<String, Vec<String>>,
    }

    const SCHEMA: &str = "
        CREATE TABLE IF NOT EXISTS tasks (
            key      TEXT PRIMARY KEY,
            title    TEXT NOT NULL,
            notes    TEXT NOT NULL,
            project  TEXT NOT NULL,
            when_on  TEXT NOT NULL,
            deadline TEXT NOT NULL,
            reminder TEXT NOT NULL,
            done     INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            key  TEXT PRIMARY KEY,
            name TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS project_order (
            project  TEXT NOT NULL,
            position INTEGER NOT NULL,
            task     TEXT NOT NULL,
            PRIMARY KEY (project, position)
        );";

    /// The open database and whether it is NEW — the seed runs only for a
    /// database that did not exist, which is what makes a relaunch show
    /// the user's own tasks rather than the sample ones again.
    pub(super) struct Store {
        conn: Connection,
        pub fresh: bool,
    }

    pub(super) fn open() -> Option<Store> {
        let path = kaya::app_data_dir().join("tasks.sqlite");
        let fresh = !path.exists();
        let conn = match Connection::open(&path) {
            Ok(conn) => conn,
            Err(e) => {
                // A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED: the
                // path and sqlite's own sentence, which names the cause.
                eprintln!("tasks: {} could not be opened: {e}", path.display());
                return None;
            }
        };
        if let Err(e) = conn.execute_batch(SCHEMA) {
            eprintln!("tasks: {} has no usable schema: {e}", path.display());
            return None;
        }
        Some(Store { conn, fresh })
    }

    impl Store {
        pub fn load(&self) -> Snapshot {
            let mut snap = Snapshot::default();
            let mut rows = match self.conn.prepare(
                "SELECT key, title, notes, project, when_on, deadline, reminder, done \
                 FROM tasks",
            ) {
                Ok(stmt) => stmt,
                Err(e) => {
                    eprintln!("tasks: the tasks table would not read: {e}");
                    return snap;
                }
            };
            let mapped = rows.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    TaskRow {
                        title: row.get(1)?,
                        caption: String::new(),
                        done: row.get::<_, i64>(7)? != 0,
                        notes: row.get(2)?,
                        when: row.get(4)?,
                        deadline: row.get(5)?,
                        reminder: row.get(6)?,
                        project: row.get(3)?,
                    },
                ))
            });
            if let Ok(mapped) = mapped {
                for row in mapped.flatten() {
                    snap.tasks.insert(row.0, row.1);
                }
            }
            if let Ok(mut stmt) = self.conn.prepare("SELECT key, name FROM projects") {
                if let Ok(mapped) = stmt
                    .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
                {
                    for (key, name) in mapped.flatten() {
                        snap.order.entry(key.clone()).or_default();
                        snap.projects.insert(key, name);
                    }
                }
            }
            if let Ok(mut stmt) = self
                .conn
                .prepare("SELECT project, task FROM project_order ORDER BY project, position")
            {
                if let Ok(mapped) = stmt
                    .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
                {
                    for (project, task) in mapped.flatten() {
                        snap.order.entry(project).or_default().push(task);
                    }
                }
            }
            snap
        }

        /// ONE TRANSACTION PER SAVE, and the whole model in it: this
        /// document is ten rows, so the delta bookkeeping a bigger one
        /// would need buys nothing and can disagree with the model.
        pub fn save(&mut self, snap: &Snapshot) {
            let write = |tx: &rusqlite::Transaction| -> rusqlite::Result<()> {
                tx.execute("DELETE FROM tasks", [])?;
                tx.execute("DELETE FROM projects", [])?;
                tx.execute("DELETE FROM project_order", [])?;
                for (key, row) in &snap.tasks {
                    tx.execute(
                        "INSERT INTO tasks (key, title, notes, project, when_on, deadline, \
                         reminder, done) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                        rusqlite::params![
                            key,
                            row.title,
                            row.notes,
                            row.project,
                            row.when,
                            row.deadline,
                            row.reminder,
                            i64::from(row.done),
                        ],
                    )?;
                }
                for (key, name) in &snap.projects {
                    tx.execute(
                        "INSERT INTO projects (key, name) VALUES (?1, ?2)",
                        rusqlite::params![key, name],
                    )?;
                }
                for (project, keys) in &snap.order {
                    for (at, task) in keys.iter().enumerate() {
                        tx.execute(
                            "INSERT INTO project_order (project, position, task) \
                             VALUES (?1, ?2, ?3)",
                            rusqlite::params![project, at as i64, task],
                        )?;
                    }
                }
                Ok(())
            };
            let result = self
                .conn
                .transaction()
                .and_then(|tx| write(&tx).and_then(|()| tx.commit()));
            if let Err(e) = result {
                eprintln!("tasks: the document would not be written: {e}");
            }
        }
    }
}

/// The settings' preference keys (docs/tasks-s4-plan.md P7). `week_start`
/// is 0 Monday / 1 Sunday; the appearance is the word, so `defaults read`
/// and the key file both say what the user chose.
const PREF_WEEK_START: &str = "week_start";
const PREF_HIDE_BADGE: &str = "hide_badge";
const PREF_KEEP_DONE: &str = "keep_done";
const PREF_APPEARANCE: &str = "appearance";

const APPEARANCE_WORDS: [&str; 3] = ["system", "light", "dark"];

fn appearance_index(word: &str) -> usize {
    APPEARANCE_WORDS.iter().position(|w| *w == word).unwrap_or(0)
}

fn appearance_mode(index: usize) -> kaya::Appearance {
    match index {
        1 => kaya::Appearance::Light,
        2 => kaya::Appearance::Dark,
        _ => kaya::Appearance::System,
    }
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct TaskRow {
    title: String,
    caption: String,
    done: bool,
    notes: String,
    when: String,
    deadline: String,
    reminder: String,
    project: String,
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct ProjectRow {
    name: String,
    count: String,
}

// A project screen's rows are bare labels: expect_order reads label children.
#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Line {
    title: String,
}

// The Settings screen is ONE stamped row: a live checkbox has no sugar for
// an initial state, a template one binds a field (invariant 5).
#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Settings {
    week_start: f64,
    hide_badge: bool,
    keep_done: bool,
    appearance: f64,
    line: String,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum List {
    Inbox,
    Today,
    Upcoming,
    Anytime,
    Logbook,
}

#[derive(Clone)]
enum Msg {
    Draft(String),
    Add,
    Search(List, String),
    Toggle(kaya::Path, bool),
    Details(kaya::Path),
    Notes(String),
    When(kaya::Date),
    ClearWhen,
    Deadline(kaya::Date),
    ClearDeadline,
    Reminder(kaya::Time),
    ClearReminder,
    Reminded(String, kaya::NotificationOutcome),
    /// An app link named a task (docs/app-links-plan.md L4): the key is
    /// the pattern's one capture. A key no task carries opens Inbox and
    /// SAYS so, rather than dropping in silence.
    LinkTask(String),
    /// An app link named a section by name; an unknown name is dropped
    /// with the same note.
    LinkSection(String),
    /// A link no declared route took (the `*` route): the URL itself.
    LinkMiss(String),
    Project(usize),
    Delete,
    DetailPopped,
    OpenProject(kaya::Path),
    ProjectDraft(String),
    ProjectAdd,
    Reorder(kaya::Dropped),
    ProjectPopped,
    WeekStart(f64),
    HideBadge(bool),
    Appearance(f64),
    KeepDone(bool),
    Section(WindowId),
    OpenLogbook,
    LogbookPopped,
    OpenSettings,
    SettingsPopped,
    Resync,
}

const INBOX: WindowId = WindowId(10);
const TODAY: WindowId = WindowId(11);
const UPCOMING: WindowId = WindowId(12);
const ANYTIME: WindowId = WindowId(13);
const PROJECTS: WindowId = WindowId(15);
const DETAIL: WindowId = WindowId(20);
const PROJECT: WindowId = WindowId(21);
const LOGBOOK_SCREEN: WindowId = WindowId(22);
const SETTINGS_SCREEN: WindowId = WindowId(23);

fn date(year: i32, month: u8, day: u8) -> kaya::Date {
    kaya::Date::new(year, month, day).unwrap()
}

// Hinnant's days_from_civil / civil_from_days.
fn days(d: kaya::Date) -> i64 {
    let y = if d.month <= 2 { d.year as i64 - 1 } else { d.year as i64 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let m = d.month as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d.day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil(z: i64) -> kaya::Date {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u8;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u8;
    date((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

fn short(d: kaya::Date) -> String {
    const DAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    format!("{} {} {}", DAYS[days(d).rem_euclid(7) as usize], d.day, MONTHS[(d.month - 1) as usize])
}

/// A REMINDER'S NOTIFICATION ID IS ITS TASK'S KEY (docs/tasks-s9-plan.md
/// R2): a relaunched process has none of the old one's memory, so the id
/// has to be derivable both ways from something that survives. Keys are
/// minted `t1`, `t2`, …
fn notification_id(key: &str) -> Option<u64> {
    key.strip_prefix('t')?.parse().ok()
}

fn task_key(notification: kaya::NotificationId) -> String {
    format!("t{}", notification.0)
}

fn today() -> kaya::Date {
    if std::env::var_os("KAYA_SELFTEST").is_some() {
        return date(2026, 9, 7);
    }
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    civil(secs.div_euclid(86_400))
}

fn date_field(d: Option<kaya::Date>) -> String {
    d.map_or(String::new(), |d| format!("{:04}-{:02}-{:02}", d.year, d.month, d.day))
}

fn parse_date(s: &str) -> Option<kaya::Date> {
    let mut it = s.split('-');
    let y = it.next()?.parse().ok()?;
    let m = it.next()?.parse().ok()?;
    let d = it.next()?.parse().ok()?;
    kaya::Date::new(y, m, d).ok()
}

fn time_field(t: Option<kaya::Time>) -> String {
    t.map_or(String::new(), |t| format!("{:02}:{:02}", t.hour, t.minute))
}

fn parse_time(s: &str) -> Option<kaya::Time> {
    let (h, m) = s.split_once(':')?;
    kaya::Time::new(h.parse().ok()?, m.parse().ok()?).ok()
}

fn key_of(path: &kaya::Path) -> String {
    match path.first() {
        Some(kaya::Value::Str(s)) => s.clone(),
        other => panic!("tasks: a row key that is not a string: {other:?}"),
    }
}

// Five sections on purpose (docs/tasks-plan.md R4): the Logbook is a
// menu-reached screen, so it has no section of its own.
fn section_of(list: List) -> Option<WindowId> {
    match list {
        List::Inbox => Some(INBOX),
        List::Today => Some(TODAY),
        List::Upcoming => Some(UPCOMING),
        List::Anytime => Some(ANYTIME),
        List::Logbook => None,
    }
}

struct Detail {
    key: String,
    // Stacks are per surface (DESIGN.md, Sections): the detail is pushed
    // onto the section the row was in, and popped from it.
    section: WindowId,
    when_text: kaya::SignalId,
    deadline_text: kaya::SignalId,
    reminder_text: kaya::SignalId,
}

struct App {
    today: kaya::Date,
    lists: Vec<(List, kaya::Collection<TaskRow>)>,
    projects_coll: kaya::Collection<ProjectRow>,
    // Caches of the collections: rebuilt from them after undo and redo.
    tasks: BTreeMap<String, (List, TaskRow)>,
    // The per-list search (docs/search-plan.md S9, S10): the query, and the
    // rows it has taken OUT of their collection — the app owns the filter,
    // and a hidden row lives here and in `tasks`, in no collection.
    queries: BTreeMap<List, String>,
    hidden: BTreeMap<String, (List, TaskRow)>,
    counts: BTreeMap<List, kaya::SignalId>,
    today_badge: kaya::SignalId,
    /// What the last app link did when it named nothing (L4). Empty
    /// otherwise, and cleared by the next link that lands.
    link_note: kaya::SignalId,
    projects: BTreeMap<String, String>,
    order: BTreeMap<String, Vec<String>>,
    next: u32,
    detail: Option<Detail>,

    pending_open: Option<String>,
    can_notify: bool,
    open_project: Option<(String, kaya::Collection<Line>)>,
    // The selected section: the surface the menu's screens push onto.
    active: WindowId,
    logbook_screen: Option<kaya::Collection<TaskRow>>,
    settings_screen: Option<kaya::Collection<Settings>>,
    draft: String,
    pdraft: String,
    week_start: usize,
    appearance: usize,
    hide_badge: bool,
    keep_done: bool,
    /// The app's own document and the last thing written to it: the loop
    /// saves after a handler's transaction has committed, and only when
    /// the snapshot moved (docs/tasks-s4-plan.md P7).
    store: Option<store::Store>,
    saved: store::Snapshot,
}

impl App {
    fn coll(&self, list: List) -> kaya::Collection<TaskRow> {
        self.lists.iter().find(|(l, _)| *l == list).map(|(_, c)| c.clone()).unwrap()
    }

    fn list_of(&self, row: &TaskRow) -> List {
        if row.done && !self.keep_done {
            return List::Logbook;
        }
        let today = days(self.today);
        if parse_date(&row.deadline).is_some_and(|d| days(d) <= today) {
            return List::Today;
        }
        match parse_date(&row.when) {
            Some(w) if days(w) <= today => List::Today,
            Some(_) => List::Upcoming,
            None if row.project.is_empty() => List::Inbox,
            None => List::Anytime,
        }
    }

    fn matches(&self, list: List, row: &TaskRow) -> bool {
        let Some(query) = self.queries.get(&list).filter(|q| !q.is_empty()) else { return true };
        let query = query.to_lowercase();
        row.title.to_lowercase().contains(&query) || row.notes.to_lowercase().contains(&query)
    }

    fn count_text(&self, list: List) -> String {
        let total = self.tasks.values().filter(|(l, _)| *l == list).count();
        let hidden = self.hidden.values().filter(|(l, _)| *l == list).count();
        if self.queries.get(&list).is_some_and(|q| !q.is_empty()) {
            return format!("{} of {total} match", total - hidden);
        }
        match list {
            List::Inbox => format!("{total} in inbox"),
            List::Today => format!("{total} today"),
            List::Upcoming => format!("{total} upcoming"),
            List::Anytime => format!("{total} anytime"),
            List::Logbook => format!("{total} done"),
        }
    }

    fn update_count(&self, tx: &mut kaya::Tx, list: List) {
        if let Some(sig) = self.counts.get(&list) {
            tx.write(*sig, self.count_text(list));
        }
        if list == List::Today {
            let total = self.tasks.values().filter(|(l, _)| *l == list).count();
            let shown = if self.hide_badge { 0 } else { total };
            tx.write(self.today_badge, shown as f64);
        }
    }

    /// The list's visible set follows its query: a DIFF of removes and
    /// inserts by key, never undoable, the rows back in creation order.
    fn apply_filter(&mut self, tx: &mut kaya::Tx, list: List) {
        let coll = self.coll(list);
        let mut keys: Vec<(u32, String)> = self
            .tasks
            .iter()
            .filter(|(_, (l, _))| *l == list)
            .map(|(k, _)| (k.trim_start_matches('t').parse::<u32>().unwrap_or(0), k.clone()))
            .collect();
        keys.sort();
        let mut inserted = false;
        for (_, key) in &keys {
            let (_, row) = self.tasks[key].clone();
            let want = self.matches(list, &row);
            let visible = !self.hidden.contains_key(key);
            if want && !visible {
                self.hidden.remove(key);
                tx.insert(&coll, key.clone(), row);
                inserted = true;
            } else if !want && visible {
                self.hidden.insert(key.clone(), (list, row));
                tx.remove(&coll, key.clone());
            }
        }
        if inserted {
            for (_, key) in &keys {
                if !self.hidden.contains_key(key) {
                    tx.move_to_end(&coll, key.clone());
                }
            }
        }
        self.update_count(tx, list);
    }

    fn caption(&self, row: &TaskRow) -> String {
        let mut parts = Vec::new();
        if let Some(w) = parse_date(&row.when) {
            parts.push(short(w));
        }
        if let Some(d) = parse_date(&row.deadline) {
            parts.push(format!("due {}", short(d)));
        }
        if let Some(name) = self.projects.get(&row.project) {
            parts.push(name.clone());
        }
        parts.join(", ")
    }

    /// Put the task where its fields say it belongs; the caller opens the
    /// undo group.
    fn place(&mut self, tx: &mut kaya::Tx, key: &str, mut row: TaskRow) {
        row.caption = self.caption(&row);
        let target = self.list_of(&row);
        let current = self.tasks.get(key).map(|(l, _)| *l);
        // A row a filter has hidden is in no collection: nothing to patch or
        // remove; apply_filter below decides whether it comes back.
        let was_hidden = self.hidden.remove(key).is_some();
        match current {
            Some(cur) if cur == target => {
                if !was_hidden {
                    self.coll(cur)
                        .patch(tx, key.to_string())
                        .title(row.title.clone())
                        .caption(row.caption.clone())
                        .done(row.done)
                        .notes(row.notes.clone())
                        .when(row.when.clone())
                        .deadline(row.deadline.clone())
                        .reminder(row.reminder.clone())
                        .project(row.project.clone());
                }
            }
            Some(cur) => {
                if !was_hidden {
                    tx.remove(&self.coll(cur), key.to_string());
                }
                tx.insert(&self.coll(target), key.to_string(), row.clone());
            }
            None => tx.insert(&self.coll(target), key.to_string(), row.clone()),
        }
        if was_hidden && current == Some(target) {
            tx.insert(&self.coll(target), key.to_string(), row.clone());
        }
        self.tasks.insert(key.to_string(), (target, row));
        self.apply_filter(tx, target);
        if let Some(cur) = current.filter(|c| *c != target) {
            self.update_count(tx, cur);
        }
    }

    fn project_count(&mut self, tx: &mut kaya::Tx, project: &str) {
        if !self.projects.contains_key(project) {
            return;
        }
        let n = self
            .tasks
            .values()
            .filter(|(_, r)| r.project == project && !r.done)
            .count();
        let text = if n == 1 { "1 task".to_string() } else { format!("{n} tasks") };
        self.projects_coll.patch(tx, project.to_string()).count(text);
    }

    fn resync(&mut self, tx: &mut kaya::Tx) {
        self.tasks.clear();
        for (list, coll) in self.lists.clone() {
            for (key, row) in tx.items(&coll) {
                if let kaya::Value::Str(k) = key {
                    self.tasks.insert(k, (list, row));
                }
            }
        }
        // The rows a filter holds out of their collections are model too.
        for (key, entry) in &self.hidden {
            self.tasks.insert(key.clone(), entry.clone());
        }
        // Undo may have put a row back that the filter hides: the diff runs
        // again, and every count is rewritten from the model.
        for list in [List::Inbox, List::Today, List::Upcoming, List::Anytime] {
            self.apply_filter(tx, list);
        }
        if let Some((project, lines)) = self.open_project.clone() {
            let order: Vec<String> = tx
                .items(&lines)
                .into_iter()
                .filter_map(|(k, _)| match k {
                    kaya::Value::Str(s) => Some(s),
                    _ => None,
                })
                .collect();
            self.order.insert(project, order);
        }
    }

    fn settings_row(&self) -> Settings {
        Settings {
            week_start: self.week_start as f64,
            appearance: self.appearance as f64,
            hide_badge: self.hide_badge,
            keep_done: self.keep_done,
            line: format!(
                "Week starts {}; badge {}; completed {}",
                ["Monday", "Sunday"][self.week_start],
                if self.hide_badge { "hidden" } else { "shown" },
                if self.keep_done { "stay in place" } else { "move to Logbook" },
            ),
        }
    }

    /// What survives a relaunch. Read out of the model rather than kept
    /// beside it: undo and redo rewrite `tasks` wholesale (resync), and a
    /// second copy would go stale exactly there.
    fn snapshot(&self) -> store::Snapshot {
        store::Snapshot {
            tasks: self.tasks.iter().map(|(k, (_, row))| (k.clone(), row.clone())).collect(),
            projects: self.projects.clone(),
            order: self.order.clone(),
        }
    }

    /// AFTER THE TRANSACTION COMMITS, once per message: the loop calls
    /// this at the bottom of every handler, and a snapshot that did not
    /// move writes nothing — a keystroke in the quick-add field is not a
    /// document change.
    fn save(&mut self) {
        let snap = self.snapshot();
        if snap == self.saved {
            return;
        }
        if let Some(store) = self.store.as_mut() {
            store.save(&snap);
        }
        self.saved = snap;
    }

    /// Mirror the settings into the open screen's row, if one is open.
    fn write_settings(&self, ctx: &kaya::AppCtx) {
        let Some(screen) = self.settings_screen.clone() else { return };
        let row = self.settings_row();
        ctx.apply(|tx| {
            screen
                .patch(tx, "s")
                .week_start(row.week_start)
                .hide_badge(row.hide_badge)
                .keep_done(row.keep_done)
                .appearance(row.appearance)
                .line(row.line);
        });
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    // THE APP LINKS, BEFORE THE FIRST TRANSACTION (docs/app-links-plan.md
    // §4): the declarations ride its head, so a link that STARTED this
    // process is matched the moment that batch lands.
    msgs.link("task/{key}", |p| Msg::LinkTask(p.get("key").unwrap_or_default().to_owned()));
    msgs.link("{section}", |p| {
        Msg::LinkSection(p.get("section").unwrap_or_default().to_owned())
    });
    msgs.link("*", |p| Msg::LinkMiss(p.get("url").unwrap_or_default().to_owned()));
    let today = today();

    // THE SETTINGS, BEFORE THE FIRST BUILD (docs/tasks-s4-plan.md P7):
    // the window's appearance is declared in the first transaction below,
    // so the choice has to be in hand before it.
    let prefs = kaya::prefs();
    let week_start = prefs.get_i64(PREF_WEEK_START, 0).clamp(0, 1) as usize;
    let hide_badge = prefs.get_bool(PREF_HIDE_BADGE, false);
    let keep_done = prefs.get_bool(PREF_KEEP_DONE, false);
    let appearance = appearance_index(&prefs.get_string(PREF_APPEARANCE, "system"));
    // AND THE DOCUMENT, before the seed: a database that already exists
    // is the user's own tasks, and the seed is the empty app's furniture.
    let store = store::open();
    let loaded = store.as_ref().map(|s| s.load()).unwrap_or_default();
    let seed_wanted = store.as_ref().is_none_or(|s| s.fresh);

    let (lists, projects_coll, quick, counts, today_badge, link_note) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("tasks")
            // A desktop default that fits the details screen (GTK's own
            // default is 540x330); advisory on the phones, and beaten at
            // launch by the frame kaya remembered (P4).
            .size(960.0, 640.0)
            // The choice the last run left, applied process-wide before
            // the first frame (S2b R1, P7).
            .appearance(appearance_mode(appearance))
            .sections_presentation(kaya::SectionsPresentation::Sidebar)
            .menu("Edit", |m| {
                m.item("Undo").role(kaya::MenuRole::Undo).id();
                m.item("Redo").role(kaya::MenuRole::Redo).id();
            })
            .id();
        tx.window(kaya::DEFAULT_WINDOW)
            .menu("View", |m| {
            let logbook = m.item("Logbook").symbol(kaya::Symbol::Done).id();
            msgs.on_menu_item(logbook, Msg::OpenLogbook);
            // Promoted into the chrome: a gear on the phones' top bar and
            // the desktops' toolbar (DESIGN.md, chrome promotion).
            let settings = m.item("Settings").symbol(kaya::Symbol::Settings).primary(true).id();
            msgs.on_menu_item(settings, Msg::OpenSettings);
            })
            .id();

        let sections = [
            (List::Inbox, INBOX, "Inbox", kaya::Symbol::Home),
            (List::Today, TODAY, "Today", kaya::Symbol::Star),
            (List::Upcoming, UPCOMING, "Upcoming", kaya::Symbol::Forward),
            (List::Anytime, ANYTIME, "Anytime", kaya::Symbol::More),
        ];
        let mut lists = Vec::new();
        let mut counts = BTreeMap::new();
        let mut quick = kaya::WidgetId(0);
        let today_badge = tx.signal(0.0);
        let link_note = tx.signal("");
        for (list, window, name, symbol) in sections {
            let mut declared = tx.add_section(window).title(name).symbol(symbol);
            if list == List::Today {
                declared = declared.badge(today_badge);
            }
            let section = declared.id();
            msgs.on_section_selected(section, Msg::Section(window));
            let coll = tx.collection::<TaskRow>();
            // Written by the app (count_text): a derived signal could count
            // the visible rows and not the total a filter hides.
            let count = tx.signal(match list {
                List::Inbox => "0 in inbox",
                List::Today => "0 today",
                List::Upcoming => "0 upcoming",
                List::Anytime => "0 anytime",
                List::Logbook => "0 done",
            });
            counts.insert(list, count);
            let count_id = match list {
                List::Inbox => "inbox_count",
                List::Today => "today_count",
                List::Upcoming => "upcoming_count",
                List::Anytime => "anytime_count",
                List::Logbook => unreachable!("the logbook has no section"),
            };
            let root = tx
                .column(|tx| {
                    // The list's search field, first, filtering this list
                    // alone (docs/search-plan.md S10).
                    let find = tx
                        .search()
                        .placeholder("Search")
                        .a11y_id(format!("{}_find", count_id.trim_end_matches("_count")))
                        .id();
                    msgs.on_change(find, move |q| Msg::Search(list, q));
                    tx.caption(count).a11y_id(count_id).id();
                    if list == List::Inbox {
                        // WHAT AN APP LINK DID WHEN IT NAMED NOTHING
                        // (docs/app-links-plan.md L4): empty otherwise.
                        tx.caption(link_note).a11y_id("link_note").id();
                    }
                    if list == List::Inbox {
                        tx.row(|tx| {
                            quick = tx.entry().a11y_id("quick").grow(1.0).id();
                            msgs.on_change(quick, Msg::Draft);
                            let add = tx.button("Add").a11y_id("add").id();
                            msgs.on_click(add, Msg::Add);
                        })
                        .id();
                    }
                    let rows = coll.rows(tx);
                    let list_column = rows.id();
                    for mut row in rows {
                        let (task_row, _) = row.row(|t| {
                            let done = t.checkbox(TaskRow::done());
                            t.a11y_id(done, "done");
                            msgs.on_toggle_node(done, Msg::Toggle);
                            let title = t.label(TaskRow::title());
                            t.a11y_id(title, "title");
                            let caption = t.caption(TaskRow::caption());
                            t.a11y_id(caption, "caption");
                            // The trailing accessory: a spacer takes the row's
                            // free width so every Details button shares one edge.
                            t.spacer();
                            let details = t.button("Details");
                            t.a11y_id(details, "details");
                            t.role(details, kaya::Role::Plain);
                            msgs.on_click_node(details, Msg::Details);
                        });
                        row.a11y_id(task_row, "task");
                    }
                    // The list's column is named so the scene can hold it to
                    // the section's width (R7): a hugging list hides behind
                    // rows that fill it.
                    tx.a11y_id(list_column, format!("{}_list", count_id.trim_end_matches("_count")));
                })
                .id();
            tx.mount_in(section, root);
            lists.push((list, coll));
        }
        // The logbook's membership lives in the core so undo restores it;
        // its rows are shown by the View>Logbook screen, stamped on open.
        lists.push((List::Logbook, tx.collection::<TaskRow>()));

        let projects_section = tx.add_section(PROJECTS).title("Projects").symbol(kaya::Symbol::Edit).id();
        msgs.on_section_selected(projects_section, Msg::Section(PROJECTS));
        let projects_coll = tx.collection::<ProjectRow>();
        let projects_root = tx
            .column(|tx| {
                for mut row in projects_coll.rows(tx) {
                    row.row(|t| {
                        let name = t.label(ProjectRow::name());
                        t.a11y_id(name, "name");
                        let count = t.caption(ProjectRow::count());
                        t.a11y_id(count, "pcount");
                        t.spacer();
                        let open = t.button("Open");
                        t.a11y_id(open, "open");
                        t.role(open, kaya::Role::Plain);
                        msgs.on_click_node(open, Msg::OpenProject);
                    });
                }
            })
            .id();
        tx.mount_in(projects_section, projects_root);
        (lists, projects_coll, quick, counts, today_badge, link_note)
    });
    msgs.on_undone(kaya::DEFAULT_WINDOW, |_, _| Msg::Resync);
    msgs.on_redone(kaya::DEFAULT_WINDOW, |_, _| Msg::Resync);
    // THE TAP THAT STARTED THIS PROCESS (docs/tasks-s9-plan.md R1): a
    // reminder posted by a run that has since exited has no one-shot
    // registration here, and its id is its task's key.
    msgs.on_notification_activation(|notification, outcome| {
        Msg::Reminded(task_key(notification), outcome)
    });

    let mut app = App {
        today,
        lists,
        projects_coll,
        tasks: BTreeMap::new(),
        queries: BTreeMap::new(),
        hidden: BTreeMap::new(),
        counts,
        today_badge,
        link_note,
        projects: BTreeMap::new(),
        order: BTreeMap::new(),
        next: 1,
        detail: None,
        pending_open: None,
        can_notify: kaya::capabilities().notifications,
        open_project: None,
        active: INBOX,
        logbook_screen: None,
        settings_screen: None,
        draft: String::new(),
        pdraft: String::new(),
        week_start,
        appearance,
        hide_badge,
        keep_done,
        store,
        saved: store::Snapshot::default(),
    };

    // THE DOCUMENT, OR THE SEED — never both (docs/tasks-s4-plan.md P7).
    // A database that already exists holds the user's own tasks; the seed
    // is what an empty app comes with, against the fixed clock
    // (docs/tasks-plan.md §1).
    if seed_wanted {
        ctx.apply(|tx| {
            for (key, name) in [("kitchen", "Kitchen"), ("thesis", "Thesis"), ("trip", "Trip")] {
                app.projects.insert(key.to_string(), name.to_string());
                app.order.insert(key.to_string(), Vec::new());
                tx.insert(&app.projects_coll, key, ProjectRow { name: name.into(), count: "0 tasks".into() });
            }
            let seed: [(&str, &str, Option<kaya::Date>, Option<kaya::Date>, &str, bool); 9] = [
                ("Buy milk", "", None, None, "", false),
                ("Call the plumber", "", None, None, "", false),
                ("Draft chapter 3", "Aim for twelve pages.", Some(date(2026, 9, 7)), None, "thesis", false),
                ("Water the plants", "", Some(date(2026, 9, 7)), None, "", false),
                ("Book the flights", "", Some(date(2026, 9, 9)), None, "trip", false),
                ("Renew passport", "", None, Some(date(2026, 9, 30)), "trip", false),
                ("Sharpen knives", "", None, None, "kitchen", false),
                ("Read reviewer comments", "", Some(date(2026, 9, 12)), None, "thesis", false),
                ("Fix the leaking tap", "", None, None, "kitchen", true),
            ];
            for (title, notes, when, deadline, project, done) in seed {
                let key = format!("t{}", app.next);
                app.next += 1;
                let row = TaskRow {
                    title: title.into(),
                    caption: String::new(),
                    done,
                    notes: notes.into(),
                    when: date_field(when),
                    deadline: date_field(deadline),
                    reminder: String::new(),
                    project: project.into(),
                };
                if !project.is_empty() {
                    app.order.get_mut(project).unwrap().push(key.clone());
                }
                app.place(tx, &key, row);
            }
            for project in ["kitchen", "thesis", "trip"] {
                app.project_count(tx, project);
            }
        });
    } else {
        ctx.apply(|tx| {
            for (key, name) in &loaded.projects {
                app.projects.insert(key.clone(), name.clone());
                app.order
                    .insert(key.clone(), loaded.order.get(key).cloned().unwrap_or_default());
                tx.insert(
                    &app.projects_coll,
                    key.clone(),
                    ProjectRow { name: name.clone(), count: "0 tasks".into() },
                );
            }
            // KEYS ARE `t<n>` AND THE COUNTER RESUMES PAST THE HIGHEST:
            // a task's key is also its notification id (S9 R2), so a
            // reused one would re-post under an existing reminder.
            let mut keys: Vec<(u32, &String)> = loaded
                .tasks
                .keys()
                .map(|k| (k.trim_start_matches('t').parse::<u32>().unwrap_or(0), k))
                .collect();
            keys.sort();
            for (n, key) in keys {
                app.next = app.next.max(n + 1);
                app.place(tx, key, loaded.tasks[key].clone());
            }
            let projects: Vec<String> = app.projects.keys().cloned().collect();
            for project in projects {
                app.project_count(tx, &project);
            }
        });
    }
    if seed_wanted {
        // The seed IS the document's first content; `saved` is still the
        // empty default, so this writes it.
        app.save();
    } else {
        // What the model holds IS what the document holds, so the first
        // handler's save writes only what the user changed.
        app.saved = app.snapshot();
    }

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => app.draft = text,
            Msg::Search(list, query) => {
                // Never undoable: a search must not un-type under Undo.
                app.queries.insert(list, query);
                ctx.apply(|tx| app.apply_filter(tx, list));
            }
            Msg::Add => {
                if app.draft.trim().is_empty() {
                    continue;
                }
                let key = format!("t{}", app.next);
                app.next += 1;
                let row = TaskRow {
                    title: app.draft.trim().to_string(),
                    caption: String::new(),
                    done: false,
                    notes: String::new(),
                    when: String::new(),
                    deadline: String::new(),
                    reminder: String::new(),
                    project: String::new(),
                };
                ctx.apply(|tx| {
                    tx.undoable(format!("add {}", row.title));
                    app.place(tx, &key, row);
                });
                ctx.apply(|tx| {
                    tx.clear(quick);
                    tx.focus(quick);
                });
                app.draft.clear();
            }
            Msg::Toggle(path, checked) => {
                let key = key_of(&path);
                let Some((was, row)) = app.tasks.get(&key).cloned() else { continue };
                let row = TaskRow { done: checked, ..row };
                let project = row.project.clone();
                ctx.apply(|tx| {
                    tx.undoable(if checked { "complete" } else { "reopen" });
                    app.place(tx, &key, row.clone());
                    app.project_count(tx, &project);
                    // A row reopened from the Logbook screen leaves its list.
                    if was == List::Logbook {
                        if let Some(screen) = app.logbook_screen.clone() {
                            tx.remove(&screen, key.clone());
                        }
                    }
                });
                ctx.apply(|tx| app.sync_reminder(tx, &msgs, &key, &row));
            }
            Msg::Details(path) => open_details(&mut app, &ctx, &msgs, key_of(&path)),
            Msg::Notes(text) => {
                let Some(key) = app.detail.as_ref().map(|d| d.key.clone()) else { continue };
                let Some((_, row)) = app.tasks.get(&key).cloned() else { continue };
                let row = TaskRow { notes: text, ..row };
                ctx.apply(|tx| {
                    tx.undoable("edit notes");
                    app.place(tx, &key, row);
                });
            }
            Msg::When(d) | Msg::Deadline(d) => {
                let is_when = matches!(msg, Msg::When(_));
                app.set_date(&ctx, &msgs, is_when, Some(d));
            }
            Msg::ClearWhen => app.set_date(&ctx, &msgs, true, None),
            Msg::ClearDeadline => app.set_date(&ctx, &msgs, false, None),
            Msg::Reminder(t) => app.set_reminder(&ctx, &msgs, Some(t)),
            Msg::ClearReminder => app.set_reminder(&ctx, &msgs, None),
            Msg::Reminded(key, outcome) => {
                if outcome != kaya::NotificationOutcome::Activated || !app.tasks.contains_key(&key) {
                    continue;
                }
                match app.detail.as_ref() {
                    Some(d) if d.key == key => {}
                    Some(d) => {
                        let section = d.section;
                        app.pending_open = Some(key);
                        ctx.apply(|tx| tx.pop_entry_in(section));
                    }
                    None => open_details(&mut app, &ctx, &msgs, key),
                }
            }
            // A LINK NAMED A TASK (docs/app-links-plan.md L4). The
            // Reminded arm's shape one door over: a details screen
            // already open is popped first and reopened on the new key.
            Msg::LinkTask(key) => {
                if !app.tasks.contains_key(&key) {
                    let note = format!("no task named {key}");
                    ctx.apply(|tx| {
                        tx.write(app.link_note, note);
                        tx.select_section(INBOX);
                    });
                    // A programmatic selection is configuration and never
                    // echoes, so the app moves its own mark.
                    app.active = INBOX;
                    continue;
                }
                ctx.apply(|tx| tx.write(app.link_note, ""));
                match app.detail.as_ref() {
                    Some(d) if d.key == key => {}
                    Some(d) => {
                        let section = d.section;
                        app.pending_open = Some(key);
                        ctx.apply(|tx| tx.pop_entry_in(section));
                    }
                    None => open_details(&mut app, &ctx, &msgs, key),
                }
            }
            // A LINK NAMED A SECTION, by the name the section carries.
            Msg::LinkSection(name) => {
                let wanted = match name.as_str() {
                    "inbox" => Some(INBOX),
                    "today" => Some(TODAY),
                    "upcoming" => Some(UPCOMING),
                    "anytime" => Some(ANYTIME),
                    "projects" => Some(PROJECTS),
                    _ => None,
                };
                let Some(section) = wanted else {
                    let note = format!("no section named {name}");
                    ctx.apply(|tx| tx.write(app.link_note, note));
                    continue;
                };
                ctx.apply(|tx| {
                    tx.write(app.link_note, "");
                    tx.select_section(section);
                });
                app.active = section;
            }
            // A LINK NO ROUTE TOOK: Inbox, and the note names the URL.
            Msg::LinkMiss(url) => {
                let note = format!("no route for {url}");
                ctx.apply(|tx| {
                    tx.write(app.link_note, note);
                    tx.select_section(INBOX);
                });
                app.active = INBOX;
            }
            Msg::Project(index) => {
                let Some(key) = app.detail.as_ref().map(|d| d.key.clone()) else { continue };
                let Some((_, row)) = app.tasks.get(&key).cloned() else { continue };
                let new_project = if index == 0 {
                    String::new()
                } else {
                    app.projects.keys().nth(index - 1).cloned().unwrap_or_default()
                };
                let old_project = row.project.clone();
                if new_project == old_project {
                    continue;
                }
                let row = TaskRow { project: new_project.clone(), ..row };
                if let Some(order) = app.order.get_mut(&old_project) {
                    order.retain(|k| *k != key);
                }
                if let Some(order) = app.order.get_mut(&new_project) {
                    order.push(key.clone());
                }
                ctx.apply(|tx| {
                    tx.undoable("move to project");
                    app.place(tx, &key, row);
                    app.project_count(tx, &old_project);
                    app.project_count(tx, &new_project);
                });
            }
            Msg::Delete => {
                let Some((key, section)) = app.detail.as_ref().map(|d| (d.key.clone(), d.section)) else { continue };
                let Some((list, row)) = app.tasks.get(&key).cloned() else { continue };
                if let Some(order) = app.order.get_mut(&row.project) {
                    order.retain(|k| *k != key);
                }
                app.tasks.remove(&key);
                let hidden = app.hidden.remove(&key).is_some();
                ctx.apply(|tx| {
                    tx.undoable(format!("delete {}", row.title));
                    if !hidden {
                        tx.remove(&app.coll(list), key.clone());
                    }
                    app.project_count(tx, &row.project);
                    app.update_count(tx, list);
                });
                ctx.apply(|tx| {
                    app.drop_reminder(tx, &key);
                    tx.pop_entry_in(section);
                });
                app.detail = None;
            }
            Msg::DetailPopped => {
                app.detail = None;
                if let Some(key) = app.pending_open.take() {
                    open_details(&mut app, &ctx, &msgs, key);
                }
            }
            Msg::OpenProject(path) => {
                let project = key_of(&path);
                let Some(name) = app.projects.get(&project).cloned() else { continue };
                let order = app.order.get(&project).cloned().unwrap_or_default();
                let titles: Vec<(String, String)> = order
                    .iter()
                    .filter_map(|k| app.tasks.get(k).map(|(_, r)| (k.clone(), r.title.clone())))
                    .collect();
                let (lines, padd) = ctx.apply(|tx| {
                    let entry = tx.push_entry_in(PROJECTS, PROJECT).title(&name).id();
                    let lines = tx.collection::<Line>();
                    let mut pquick = kaya::WidgetId(0);
                    let mut padd = kaya::WidgetId(0);
                    let root = tx
                        .column(|tx| {
                            tx.row(|tx| {
                                pquick = tx.entry().a11y_id("pquick").grow(1.0).id();
                                msgs.on_change(pquick, Msg::ProjectDraft);
                                padd = tx.button("Add").a11y_id("padd").id();
                                msgs.on_click(padd, Msg::ProjectAdd);
                            })
                            .id();
                            let rows = lines.rows(tx);
                            let list = rows.id();
                            for mut row in rows {
                                let title = row.label(Line::title());
                                row.a11y_id(title, "ptitle");
                            }
                            tx.reorderable(list, true);
                            tx.a11y_id(list, "rows");
                            msgs.on_drop(list, Msg::Reorder);
                        })
                        .id();
                    tx.mount_in(entry, root);
                    for (key, title) in &titles {
                        tx.insert(&lines, key.clone(), Line { title: title.clone() });
                    }
                    msgs.on_entry_popped(entry, Msg::ProjectPopped);
                    (lines, (pquick, padd))
                });
                let _ = padd;
                app.open_project = Some((project, lines));
                app.pdraft.clear();
            }
            Msg::ProjectDraft(text) => app.pdraft = text,
            Msg::ProjectAdd => {
                let Some((project, lines)) = app.open_project.clone() else { continue };
                if app.pdraft.trim().is_empty() {
                    continue;
                }
                let key = format!("t{}", app.next);
                app.next += 1;
                let row = TaskRow {
                    title: app.pdraft.trim().to_string(),
                    caption: String::new(),
                    done: false,
                    notes: String::new(),
                    when: String::new(),
                    deadline: String::new(),
                    reminder: String::new(),
                    project: project.clone(),
                };
                app.order.entry(project.clone()).or_default().push(key.clone());
                ctx.apply(|tx| {
                    tx.undoable(format!("add {}", row.title));
                    tx.insert(&lines, key.clone(), Line { title: row.title.clone() });
                    app.place(tx, &key, row);
                    app.project_count(tx, &project);
                });
                app.pdraft.clear();
            }
            Msg::Reorder(d) => {
                let Some((project, lines)) = app.open_project.clone() else { continue };
                let kaya::Representation::Custom { bytes, .. } = &d.clip else { continue };
                let moved = String::from_utf8_lossy(&bytes.0).to_string();
                let Some(kaya::Value::Str(anchor)) = d.anchor.first().cloned() else { continue };
                ctx.apply(|tx| {
                    tx.undoable("reorder");
                    if d.before {
                        tx.move_before(&lines, moved.clone(), anchor.clone());
                    } else {
                        tx.move_after(&lines, moved.clone(), anchor.clone());
                    }
                    let order: Vec<String> = tx
                        .items(&lines)
                        .into_iter()
                        .filter_map(|(k, _)| match k {
                            kaya::Value::Str(s) => Some(s),
                            _ => None,
                        })
                        .collect();
                    app.order.insert(project.clone(), order);
                });
            }
            Msg::ProjectPopped => app.open_project = None,
            Msg::WeekStart(index) => {
                app.week_start = index as usize;
                // ONE SETTING PER WRITE (docs/tasks-s4-plan.md P7): a
                // setting nobody changed was never written, which is what
                // taskspersist.steps' `expect_no_pref hide_badge` says.
                kaya::prefs().set_i64(PREF_WEEK_START, app.week_start as i64);
                app.write_settings(&ctx);
            }
            Msg::HideBadge(on) => {
                app.hide_badge = on;
                kaya::prefs().set_bool(PREF_HIDE_BADGE, on);
                app.write_settings(&ctx);
                ctx.apply(|tx| app.update_count(tx, List::Today));
            }
            Msg::Appearance(index) => {
                app.appearance = index as usize;
                kaya::prefs()
                    .set_string(PREF_APPEARANCE, APPEARANCE_WORDS[app.appearance]);
                app.write_settings(&ctx);
                let mode = appearance_mode(app.appearance);
                ctx.apply(|tx| {
                    tx.window(kaya::DEFAULT_WINDOW).appearance(mode);
                });
            }
            Msg::KeepDone(on) => {
                app.keep_done = on;
                kaya::prefs().set_bool(PREF_KEEP_DONE, on);
                let done: Vec<(String, TaskRow)> = app
                    .tasks
                    .iter()
                    .filter(|(_, (_, r))| r.done)
                    .map(|(k, (_, r))| (k.clone(), r.clone()))
                    .collect();
                ctx.apply(|tx| {
                    // Completed tasks follow the setting: re-placed, not undoable.
                    for (key, row) in done {
                        app.place(tx, &key, row);
                    }
                });
                app.write_settings(&ctx);
            }
            Msg::Section(sid) => app.active = sid,
            Msg::OpenLogbook => {
                if app.logbook_screen.is_some() {
                    continue;
                }
                let done: Vec<(String, TaskRow)> = app
                    .tasks
                    .iter()
                    .filter(|(_, (list, _))| *list == List::Logbook)
                    .map(|(k, (_, r))| (k.clone(), r.clone()))
                    .collect();
                let active = app.active;
                let screen = ctx.apply(|tx| {
                    let entry = tx.push_entry_in(active, LOGBOOK_SCREEN).title("Logbook").id();
                    let screen = tx.collection::<TaskRow>();
                    let count = screen.derive(tx, |items| format!("{} done", items.len()));
                    let root = tx
                        .column(|tx| {
                            tx.caption(count).a11y_id("logbook_count").id();
                            // Ids of this screen's own: a popped entry's copies
                            // stay in every backend's registry (docs/deferred.md,
                            // "the core never prunes self.widgets"), so a shared
                            // id would answer twice on the next keyed read.
                            for mut row in screen.rows(tx) {
                                row.row(|t| {
                                    let done = t.checkbox(TaskRow::done());
                                    t.a11y_id(done, "lb_done");
                                    msgs.on_toggle_node(done, Msg::Toggle);
                                    let title = t.label(TaskRow::title());
                                    t.a11y_id(title, "lb_title");
                                    let caption = t.caption(TaskRow::caption());
                                    t.a11y_id(caption, "lb_caption");
                                });
                            }
                        })
                        .id();
                    tx.mount_in(entry, root);
                    for (key, row) in &done {
                        tx.insert(&screen, key.clone(), row.clone());
                    }
                    msgs.on_entry_popped(entry, Msg::LogbookPopped);
                    screen
                });
                app.logbook_screen = Some(screen);
            }
            Msg::LogbookPopped => app.logbook_screen = None,
            Msg::OpenSettings => {
                if app.settings_screen.is_some() {
                    continue;
                }
                let active = app.active;
                let row = app.settings_row();
                let screen = ctx.apply(|tx| {
                    let entry = tx.push_entry_in(active, SETTINGS_SCREEN).title("Settings").id();
                    let screen = tx.collection::<Settings>();
                    let root = tx
                        .column(|tx| {
                            for mut row in screen.rows(tx) {
                                row.column(|t| {
                                    t.caption("Week starts on");
                                    let week = t.select(&["Monday", "Sunday"], Settings::week_start());
                                    t.a11y_id(week, "week");
                                    msgs.on_value_node(week, |_, index| Msg::WeekStart(index));
                                    t.caption("Appearance");
                                    let appearance =
                                        t.select(&["System", "Light", "Dark"], Settings::appearance());
                                    t.a11y_id(appearance, "appearance");
                                    msgs.on_value_node(appearance, |_, index| Msg::Appearance(index));
                                    t.row(|t| {
                                        let hide = t.checkbox(Settings::hide_badge());
                                        t.role(hide, kaya::Role::Switch);
                                        t.a11y_label(hide, "Hide the Today badge");
                                        t.a11y_id(hide, "hide_badge");
                                        msgs.on_toggle_node(hide, |_, on| Msg::HideBadge(on));
                                        t.label("Hide the Today badge");
                                    });
                                    t.row(|t| {
                                        let keep = t.checkbox(Settings::keep_done());
                                        t.role(keep, kaya::Role::Switch);
                                        t.a11y_label(keep, "Keep completed tasks in their list");
                                        t.a11y_id(keep, "keep_done");
                                        msgs.on_toggle_node(keep, |_, on| Msg::KeepDone(on));
                                        t.label("Keep completed tasks in their list");
                                    });
                                    let line = t.caption(Settings::line());
                                    t.a11y_id(line, "settings");
                                });
                            }
                        })
                        .id();
                    tx.mount_in(entry, root);
                    tx.insert(&screen, "s", row);
                    msgs.on_entry_popped(entry, Msg::SettingsPopped);
                    screen
                });
                app.settings_screen = Some(screen);
            }
            Msg::SettingsPopped => app.settings_screen = None,
            Msg::Resync => ctx.apply(|tx| app.resync(tx)),
        }
        // AFTER THE HANDLER'S TRANSACTION HAS COMMITTED (P7): every
        // `ctx.apply` above has returned, so the model and the document
        // agree at every point a process could be killed. A snapshot that
        // did not move writes nothing.
        app.save();
    }
}

// The details screen, from a row's button or a reminder's activation
// (docs/tasks-s3-plan.md N7).
fn open_details(app: &mut App, ctx: &kaya::AppCtx, msgs: &kaya::Messages<Msg>, key: String) {
    let Some((list, row)) = app.tasks.get(&key).cloned() else { return };
    let Some(section) = section_of(list) else { return };
    let names: Vec<String> = app.projects.values().cloned().collect();
    let mut options = vec!["No project"];
    options.extend(names.iter().map(String::as_str));
    let selected = app.projects.keys().position(|k| *k == row.project).map_or(0, |i| i + 1);
    let today = app.today;
    let detail = ctx.apply(|tx| {
        let entry = tx.push_entry_in(section, DETAIL).title(&row.title).id();
        let when_text = tx.signal(when_line("When", parse_date(&row.when)));
        let deadline_text = tx.signal(when_line("Deadline", parse_date(&row.deadline)));
        let reminder_text = tx.signal(reminder_line(parse_time(&row.reminder)));
        let when_sig = tx.signal(parse_date(&row.when).unwrap_or(today));
        let deadline_sig = tx.signal(parse_date(&row.deadline).unwrap_or(today));
        let reminder_sig = tx.signal(parse_time(&row.reminder).unwrap_or(kaya::Time::new(9, 0).unwrap()));
        let project_label = tx.signal("Project");
        // A form scrolls: on a phone it is taller than the screen.
        let root = tx
            .scroll(|tx| {
                tx.column(|tx| {
                let notes = tx.textarea().placeholder("Notes").a11y_id("notes").id();
                tx.set_text(notes, &row.notes);
                msgs.on_change(notes, Msg::Notes);
                let reference_text = tx.signal("Reference");
                let reference = tx.label(reference_text).role(kaya::Role::Link).a11y_id("reference").id();
                tx.href(reference, format!("https://example.com/tasks/{key}"));
                // The form (docs/forms-plan.md): four labelled rows,
                // each label naming its value, the Clear trailing.
                tx.column(|tx| {
                    tx.labeled(when_text, |tx| {
                        let picker = tx.date_picker_bound(when_sig).a11y_id("when").id();
                        msgs.on_date(picker, Msg::When);
                        let clear = tx.button("Clear").a11y_id("clear_when").id();
                        msgs.on_click(clear, Msg::ClearWhen);
                    })
                    .id();
                    tx.labeled(deadline_text, |tx| {
                        let picker = tx.date_picker_bound(deadline_sig).a11y_id("deadline").id();
                        msgs.on_date(picker, Msg::Deadline);
                        let clear = tx.button("Clear").a11y_id("clear_deadline").id();
                        msgs.on_click(clear, Msg::ClearDeadline);
                    })
                    .id();
                    tx.labeled(reminder_text, |tx| {
                        let picker = tx.time_picker_bound(reminder_sig).a11y_id("reminder").id();
                        msgs.on_time(picker, Msg::Reminder);
                        let clear = tx.button("Clear").a11y_id("clear_reminder").id();
                        msgs.on_click(clear, Msg::ClearReminder);
                    })
                    .id();
                    tx.labeled(project_label, |tx| {
                        let project = tx.select(&options, selected).a11y_id("project").id();
                        msgs.on_select(project, Msg::Project);
                    })
                    .id();
                })
                .a11y_id("details")
                .id();
                let delete = tx
                    .button("Delete")
                    .role(kaya::Role::Destructive)
                    .a11y_id("delete")
                    .id();
                msgs.on_click(delete, Msg::Delete);
                })
                .id();
            })
            .id();
        tx.mount_in(entry, root);
        msgs.on_entry_popped(entry, Msg::DetailPopped);
        Detail { key: key.clone(), section, when_text, deadline_text, reminder_text }
    });
    app.detail = Some(detail);
}

fn when_line(what: &str, d: Option<kaya::Date>) -> String {
    match d {
        Some(d) => format!("{what}: {}", short(d)),
        None => format!("{what}: none"),
    }
}

fn reminder_line(t: Option<kaya::Time>) -> String {
    match t {
        Some(t) => format!("Reminder: {:02}:{:02}", t.hour, t.minute),
        None => "Reminder: none".to_string(),
    }
}

impl App {
    fn set_date(&mut self, ctx: &kaya::AppCtx, msgs: &kaya::Messages<Msg>, is_when: bool, d: Option<kaya::Date>) {
        let Some(detail) = self.detail.as_ref() else { return };
        let key = detail.key.clone();
        let (text_sig, what) = if is_when {
            (detail.when_text, "When")
        } else {
            (detail.deadline_text, "Deadline")
        };
        let Some((_, row)) = self.tasks.get(&key).cloned() else { return };
        let row = if is_when {
            TaskRow { when: date_field(d), ..row }
        } else {
            TaskRow { deadline: date_field(d), ..row }
        };
        let line = when_line(what, d);
        ctx.apply(|tx| {
            tx.undoable(format!("set {}", what.to_lowercase()));
            tx.write(text_sig, line);
            self.place(tx, &key, row.clone());
        });
        if is_when {
            ctx.apply(|tx| self.sync_reminder(tx, msgs, &key, &row));
        }
    }

    fn set_reminder(&mut self, ctx: &kaya::AppCtx, msgs: &kaya::Messages<Msg>, t: Option<kaya::Time>) {
        let Some(detail) = self.detail.as_ref() else { return };
        let key = detail.key.clone();
        let text_sig = detail.reminder_text;
        let Some((_, row)) = self.tasks.get(&key).cloned() else { return };
        let row = TaskRow { reminder: time_field(t), ..row };
        let line = reminder_line(t);
        ctx.apply(|tx| {
            tx.undoable("set reminder");
            tx.write(text_sig, line);
            self.place(tx, &key, row.clone());
        });
        // Its own batch: an undoable group refuses a notification op.
        ctx.apply(|tx| self.sync_reminder(tx, msgs, &key, &row));
    }

    // A reminder is a notification at its time on the task's day, re-posted
    // under the same id when either moves, cancelled when it is cleared or
    // the task is done (docs/tasks-s3-plan.md N7). The instant is UTC — the
    // guest has no zone — and one already past posts now (scene.rs).
    fn sync_reminder(&mut self, tx: &mut kaya::Tx, msgs: &kaya::Messages<Msg>, key: &str, row: &TaskRow) {
        let live = if row.done { None } else { parse_time(&row.reminder) };
        let Some(t) = live else {
            self.drop_reminder(tx, key);
            return;
        };
        if !self.can_notify {
            return;
        }
        let Some(id) = notification_id(key) else { return };
        let day = parse_date(&row.when).unwrap_or(self.today);
        let at = (days(day) * 86_400 + i64::from(t.hour) * 3_600 + i64::from(t.minute) * 60) as u64;
        let shown = tx.show_notification(id).title(&row.title).body(&short(day)).at(at).show();
        let key = key.to_string();
        msgs.on_notification(shown, move |outcome| Msg::Reminded(key.clone(), outcome));
    }

    fn drop_reminder(&mut self, tx: &mut kaya::Tx, key: &str) {
        if let Some(id) = notification_id(key) {
            tx.cancel_notification(kaya::NotificationId(id));
        }
    }
}

fn main() {
    kaya::run(app)
}
