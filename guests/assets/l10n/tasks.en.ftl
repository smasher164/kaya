# The task manager's words (guests/rust/tasks.rs; docs/compliance-plan.md §6).
# Section titles and menus
inbox = Inbox
today = Today
upcoming = Upcoming
anytime = Anytime
projects = Projects
logbook = Logbook
settings = Settings
edit = Edit
undo = Undo
redo = Redo
view = View
# The list counts; numbers go through the door
inbox-count = { $count } in inbox
today-count = { $count } today
upcoming-count = { $count } upcoming
anytime-count = { $count } anytime
done-count = { $count } done
match-count = { $shown } of { $total } match
project-tasks = { $count ->
    [one] 1 task
   *[other] { $count } tasks
}
# A row's caption and the details screen
due = due { DATETIME($date, length: "weekday") }
when-label = When: { DATETIME($date, length: "weekday") }
when-none = When: none
deadline-label = Deadline: { DATETIME($date, length: "weekday") }
deadline-none = Deadline: none
reminder-label = Reminder: { DATETIME($time) }
reminder-none = Reminder: none
project = Project
no-project = No project
notes = Notes
reference = Reference
clear = Clear
delete = Delete
search = Search
new-task = New task
add = Add
details = Details
open = Open
# Settings
week-starts-on = Week starts on
monday = Monday
sunday = Sunday
appearance = Appearance
system = System
light = Light
dark = Dark
hide-badge = Hide the Today badge
keep-done = Keep completed tasks in their list
badge-shown = shown
badge-hidden = hidden
done-move = move to Logbook
done-stay = stay in place
settings-line = Week starts { $day }; badge { $badge }; completed { $done }
# Undo group names
undo-add = add { $title }
undo-delete = delete { $title }
undo-set-when = set when
undo-set-deadline = set deadline
