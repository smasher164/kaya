# The task manager's words in Arabic (guests/rust/tasks.rs; tools/scenes/tasksrtl.steps).
inbox = الوارد
today = اليوم
upcoming = القادمة
anytime = في أي وقت
projects = المشاريع
logbook = السجل
settings = الإعدادات
edit = تحرير
undo = تراجع
redo = إعادة
view = عرض
inbox-count = { $count } في الوارد
today-count = { $count } اليوم
upcoming-count = { $count } قادمة
anytime-count = { $count } في أي وقت
done-count = { $count } منجزة
match-count = { $shown } من { $total } مطابقة
project-tasks = { $count ->
    [zero] لا مهام
    [one] مهمة واحدة
    [two] مهمتان
    [few] { $count } مهام
    [many] { $count } مهمة
   *[other] { $count } مهمة
}
due = مستحق { DATETIME($date, length: "weekday") }
when-label = متى: { DATETIME($date, length: "weekday") }
when-none = متى: بلا
deadline-label = الموعد النهائي: { DATETIME($date, length: "weekday") }
deadline-none = الموعد النهائي: بلا
reminder-label = تذكير: { DATETIME($time) }
reminder-none = تذكير: بلا
project = المشروع
no-project = بلا مشروع
notes = ملاحظات
reference = مرجع
clear = مسح
delete = حذف
search = بحث
new-task = مهمة جديدة
add = إضافة
details = التفاصيل
open = فتح
week-starts-on = يبدأ الأسبوع يوم
monday = الاثنين
sunday = الأحد
appearance = المظهر
system = النظام
light = فاتح
dark = داكن
hide-badge = إخفاء شارة اليوم
keep-done = إبقاء المهام المنجزة في قائمتها
badge-shown = ظاهرة
badge-hidden = مخفية
done-move = تنتقل إلى السجل
done-stay = تبقى في مكانها
settings-line = يبدأ الأسبوع { $day }؛ الشارة { $badge }؛ المنجزة { $done }
undo-add = إضافة { $title }
undo-delete = حذف { $title }
undo-set-when = تعيين متى
undo-set-deadline = تعيين الموعد النهائي
