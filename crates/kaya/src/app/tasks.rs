use super::{AppCtx, Messages};
use crate::protocol::{
    AlertChoice, AlertSpec, DEFAULT_WINDOW, FileDialogSpec, Inbox, Occurrence, PickedFile,
    Representation, SaveDialogSpec, TxOp, WindowId,
};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc::Sender};
use std::task::{Context, Poll, Wake, Waker};

pub(super) struct Reset<'a>(pub(super) &'a Cell<bool>);

impl Drop for Reset<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

struct Ready {
    queue: Mutex<Option<VecDeque<u64>>>,
    wake: Sender<Inbox>,
}

struct TaskWake {
    ready: Arc<Ready>,
    id: u64,
    queued: AtomicBool,
}

impl Wake for TaskWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        let mut queue = self.ready.queue.lock().unwrap();
        if let Some(queue) = queue.as_mut() {
            if !self.queued.swap(true, Ordering::AcqRel) {
                queue.push_back(self.id);
                let _ = self.ready.wake.send(Inbox::Woken);
            }
        }
    }
}

struct Task<'a> {
    future: Pin<Box<dyn Future<Output = ()> + 'a>>,
    wake: Arc<TaskWake>,
}

pub struct TaskScope<'a> {
    ctx: &'a AppCtx,
    ready: Arc<Ready>,
    tasks: RefCell<HashMap<u64, Task<'a>>>,
    next_id: Cell<u64>,
    closed: Cell<bool>,
}

fn report_failure() {
    eprintln!(
        "kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed"
    );
}

mod outcome {
    pub trait Sealed {}
    impl Sealed for () {}
    impl<E: std::fmt::Display> Sealed for Result<(), E> {}
}

pub trait TaskOutcome: outcome::Sealed {
    fn report(self);
}

impl TaskOutcome for () {
    fn report(self) {}
}

impl<E: std::fmt::Display> TaskOutcome for Result<(), E> {
    fn report(self) {
        if let Err(error) = self {
            report_failure();
            eprintln!("{error}");
        }
    }
}

impl<'a> TaskScope<'a> {
    pub fn spawn<F, R>(&self, body: F)
    where
        F: AsyncFnOnce(&'a AppCtx) -> R + 'a,
        R: TaskOutcome + 'a,
    {
        assert!(
            !self.closed.get(),
            "kaya: cannot spawn into a closed task scope"
        );
        let ctx = self.ctx;
        let id = self.next_id.get();
        self.next_id
            .set(id.checked_add(1).expect("kaya: task ids exhausted"));
        let wake = Arc::new(TaskWake {
            ready: self.ready.clone(),
            id,
            queued: AtomicBool::new(false),
        });
        self.tasks.borrow_mut().insert(
            id,
            Task {
                future: Box::pin(async move {
                    body(ctx).await.report();
                }),
                wake: wake.clone(),
            },
        );
        wake.wake();
    }

    fn poll_ready(&self) {
        let batch = {
            let mut queue = self.ready.queue.lock().unwrap();
            queue.as_mut().map(std::mem::take).unwrap_or_default()
        };
        for id in batch {
            if self.ctx.shutdown.get() {
                break;
            }
            let task = self.tasks.borrow_mut().remove(&id);
            if let Some(mut task) = task {
                task.wake.queued.store(false, Ordering::Release);
                let waker = Waker::from(task.wake.clone());
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    assert_eq!(
                        self.ctx.open_transactions.get(),
                        0,
                        "kaya: task polling requires no open transaction"
                    );
                    task.future.as_mut().poll(&mut Context::from_waker(&waker))
                }));
                match result {
                    Ok(Poll::Pending) => {
                        self.tasks.borrow_mut().insert(id, task);
                    }
                    Ok(Poll::Ready(())) => Self::drop_task(task),
                    Err(_) => {
                        report_failure();
                        Self::drop_task(task);
                    }
                }
            }
        }
    }

    fn drop_task(task: Task<'_>) {
        if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(task))).is_err() {
            report_failure();
        }
    }

    pub fn next<M>(&self, messages: &Messages<M>) -> Option<M> {
        messages.next_from(self.ctx, || self.next_occurrence())
    }

    pub fn next_occurrence(&self) -> Occurrence {
        if self.closed.get() {
            return Occurrence::Shutdown;
        }
        let occurrence = self.ctx.next_with(|| self.poll_ready());
        if matches!(occurrence, Occurrence::Shutdown) {
            self.close();
        }
        occurrence
    }

    fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.ready.queue.lock().unwrap().take();
        let tasks = std::mem::take(&mut *self.tasks.borrow_mut());
        for (_, task) in tasks {
            Self::drop_task(task);
        }
        let pending = std::mem::take(&mut self.ctx.replies.borrow_mut().pending);
        for (_, reply) in pending {
            reply.close();
        }
    }
}

impl Drop for TaskScope<'_> {
    fn drop(&mut self) {
        self.close();
        self.ctx.tasks_active.set(false);
    }
}

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
enum Key {
    Alert(u64),
    File(u64),
    Clipboard(u64),
}

struct Reply<T> {
    value: Option<T>,
    waker: Option<Waker>,
    closed: bool,
}

enum Pending {
    Alert(Arc<Mutex<Reply<AlertChoice>>>),
    File(Arc<Mutex<Reply<Vec<PickedFile>>>>),
    Save(Arc<Mutex<Reply<Option<PickedFile>>>>),
    Clipboard(Arc<Mutex<Reply<Option<Representation>>>>),
}

impl Pending {
    fn close(self) {
        fn close<T>(reply: Arc<Mutex<Reply<T>>>) {
            let waker = {
                let mut state = reply.lock().unwrap();
                state.closed = true;
                state.waker.take()
            };
            if let Some(waker) = waker {
                waker.wake();
            }
        }
        match self {
            Self::Alert(reply) => close(reply),
            Self::File(reply) => close(reply),
            Self::Save(reply) => close(reply),
            Self::Clipboard(reply) => close(reply),
        }
    }
}

#[derive(Default)]
pub(super) struct Replies {
    alert: Option<u64>,
    file: Option<u64>,
    pending: HashMap<Key, Pending>,
}

impl Replies {
    pub(super) fn claim_alert(&mut self, id: u64) {
        assert!(self.alert.is_none(), "kaya: an alert is already live");
        self.alert = Some(id);
    }

    pub(super) fn claim_file(&mut self, id: u64) {
        assert!(self.file.is_none(), "kaya: a file dialog is already live");
        self.file = Some(id);
    }

    pub(super) fn abandon(&mut self, op: &TxOp) {
        match op {
            TxOp::ShowAlert(spec) if self.alert == Some(spec.alert.0) => {
                self.alert = None;
            }
            TxOp::ShowFileDialog(spec) if self.file == Some(spec.dialog.0) => {
                self.file = None;
            }
            TxOp::ShowSaveDialog(spec) if self.file == Some(spec.dialog.0) => {
                self.file = None;
            }
            _ => {}
        }
    }
}

pub struct DialogFuture<'a, T> {
    ctx: &'a AppCtx,
    key: Key,
    reply: Arc<Mutex<Reply<T>>>,
}

impl<T> Future for DialogFuture<'_, T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T> {
        assert_eq!(
            self.ctx.open_transactions.get(),
            0,
            "kaya: awaiting a dialog requires no open transaction"
        );
        let mut reply = self.reply.lock().unwrap();
        assert!(
            !reply.closed,
            "kaya: the task scope closed before this dialog answered"
        );
        if let Some(value) = reply.value.take() {
            Poll::Ready(value)
        } else {
            reply.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

impl<T> Drop for DialogFuture<'_, T> {
    fn drop(&mut self) {
        self.ctx.replies.borrow_mut().pending.remove(&self.key);
    }
}

impl AppCtx {
    pub fn tasks(&self) -> TaskScope<'_> {
        assert!(
            !self.shutdown.get(),
            "kaya: cannot open a task scope after shutdown"
        );
        assert_eq!(
            self.open_transactions.get(),
            0,
            "kaya: create the task scope outside apply"
        );
        assert!(
            !self.tasks_active.replace(true),
            "kaya: only one task scope may own the app loop"
        );
        TaskScope {
            ctx: self,
            ready: Arc::new(Ready {
                queue: Mutex::new(Some(VecDeque::new())),
                wake: self.wake.clone(),
            }),
            tasks: RefCell::new(HashMap::new()),
            next_id: Cell::new(1),
            closed: Cell::new(false),
        }
    }

    fn check_async_request(&self) {
        assert!(
            self.tasks_active.get() && !self.shutdown.get(),
            "kaya: async dialogs require a live task scope"
        );
        assert_eq!(
            self.open_transactions.get(),
            0,
            "kaya: request an async dialog outside apply"
        );
    }

    fn submit_dialog(&self, op: TxOp) {
        let mut tx = self.begin();
        {
            let mut replies = self.replies.borrow_mut();
            match &op {
                TxOp::ShowAlert(spec) => replies.claim_alert(spec.alert.0),
                TxOp::ShowFileDialog(spec) => replies.claim_file(spec.dialog.0),
                TxOp::ShowSaveDialog(spec) => replies.claim_file(spec.dialog.0),
                _ => {}
            }
        }
        tx.ops.push(op);
        if !tx.commit_inner() {
            self.shutdown.set(true);
            let mut replies = self.replies.borrow_mut();
            replies.alert = None;
            replies.file = None;
            panic!("kaya: the app transport closed before the async dialog request was sent");
        }
    }

    fn reply<T>(
        &self,
        key: Key,
        wrap: impl FnOnce(Arc<Mutex<Reply<T>>>) -> Pending,
    ) -> DialogFuture<'_, T> {
        let reply = Arc::new(Mutex::new(Reply {
            value: None,
            waker: None,
            closed: false,
        }));
        self.replies
            .borrow_mut()
            .pending
            .insert(key, wrap(reply.clone()));
        DialogFuture {
            ctx: self,
            key,
            reply,
        }
    }

    pub(super) fn resolve_reply(&self, occurrence: &Occurrence) -> bool {
        fn complete<T>(reply: Arc<Mutex<Reply<T>>>, value: T) {
            let waker = {
                let mut state = reply.lock().unwrap();
                state.value = Some(value);
                state.waker.take()
            };
            if let Some(waker) = waker {
                waker.wake();
            }
        }
        let pending = {
            let mut replies = self.replies.borrow_mut();
            match occurrence {
                Occurrence::AlertResult { alert, .. } => {
                    if replies.alert == Some(alert.0) {
                        replies.alert = None;
                    }
                    replies.pending.remove(&Key::Alert(alert.0))
                }
                Occurrence::FileDialogResult { dialog, .. } => {
                    if replies.file == Some(dialog.0) {
                        replies.file = None;
                    }
                    replies.pending.remove(&Key::File(dialog.0))
                }
                Occurrence::ClipboardResult { request, .. } => {
                    replies.pending.remove(&Key::Clipboard(*request))
                }
                Occurrence::Shutdown => {
                    self.shutdown.set(true);
                    replies.alert = None;
                    replies.file = None;
                    None
                }
                _ => None,
            }
        };
        match (pending, occurrence) {
            (Some(Pending::Alert(reply)), Occurrence::AlertResult { choice, .. }) => {
                complete(reply, *choice)
            }
            (Some(Pending::File(reply)), Occurrence::FileDialogResult { files, .. }) => {
                complete(reply, files.clone())
            }
            (Some(Pending::Save(reply)), Occurrence::FileDialogResult { files, .. }) => {
                complete(reply, files.first().cloned())
            }
            (Some(Pending::Clipboard(reply)), Occurrence::ClipboardResult { clip, .. }) => {
                complete(reply, clip.clone())
            }
            (None, _) => return false,
            _ => unreachable!("kaya: dialog reply kind disagrees with its registration"),
        }
        true
    }

    pub fn show_alert(&self) -> AlertFutureRef<'_> {
        AlertFutureRef {
            ctx: self,
            spec: AlertSpec {
                window: DEFAULT_WINDOW,
                alert: self.alloc_alert(),
                title: String::new(),
                message: String::new(),
                actions: Vec::new(),
                cancel: String::new(),
            },
        }
    }

    pub fn pick_files(&self) -> FileFutureRef<'_> {
        FileFutureRef {
            ctx: self,
            spec: FileDialogSpec {
                window: DEFAULT_WINDOW,
                dialog: self.alloc_file_dialog(),
                multiple: true,
                filters: Vec::new(),
            },
        }
    }

    pub fn pick_file(&self) -> FileFutureRef<'_> {
        let mut request = self.pick_files();
        request.spec.multiple = false;
        request
    }

    pub fn save_file(&self, name: impl Into<String>) -> SaveFutureRef<'_> {
        SaveFutureRef {
            ctx: self,
            spec: SaveDialogSpec {
                window: DEFAULT_WINDOW,
                dialog: self.alloc_file_dialog(),
                suggested_name: name.into(),
                filters: Vec::new(),
            },
        }
    }

    pub fn read_clipboard(&self) -> ClipboardFutureRef<'_> {
        ClipboardFutureRef {
            ctx: self,
            request: self.alloc_clip_read(),
            accepting: Vec::new(),
        }
    }
}

#[must_use]
pub struct AlertFutureRef<'a> {
    ctx: &'a AppCtx,
    spec: AlertSpec,
}

impl AlertFutureRef<'_> {
    pub fn title(mut self, title: &str) -> Self {
        self.spec.title = title.to_owned();
        self
    }
    pub fn message(mut self, message: &str) -> Self {
        self.spec.message = message.to_owned();
        self
    }
    pub fn action(mut self, label: &str) -> Self {
        assert!(
            self.spec.actions.len() < 2,
            "kaya: an alert supports at most two actions"
        );
        self.spec.actions.push(label.to_owned());
        self
    }
    pub fn cancel(mut self, label: &str) -> Self {
        self.spec.cancel = label.to_owned();
        self
    }
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }
}

impl<'a> IntoFuture for AlertFutureRef<'a> {
    type Output = AlertChoice;
    type IntoFuture = DialogFuture<'a, AlertChoice>;
    fn into_future(self) -> Self::IntoFuture {
        self.ctx.check_async_request();
        assert!(
            !self.spec.cancel.is_empty(),
            "kaya: the cancel slot always exists and needs a name; call .cancel(label) before awaiting"
        );
        let key = Key::Alert(self.spec.alert.0);
        self.ctx.submit_dialog(TxOp::ShowAlert(self.spec));
        self.ctx.reply(key, Pending::Alert)
    }
}

#[must_use]
pub struct FileFutureRef<'a> {
    ctx: &'a AppCtx,
    spec: FileDialogSpec,
}

impl FileFutureRef<'_> {
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }
    pub fn filter(mut self, label: impl Into<String>, extensions: impl Into<String>) -> Self {
        self.spec.filters.push((label.into(), extensions.into()));
        self
    }
}

impl<'a> IntoFuture for FileFutureRef<'a> {
    type Output = Vec<PickedFile>;
    type IntoFuture = DialogFuture<'a, Vec<PickedFile>>;
    fn into_future(self) -> Self::IntoFuture {
        self.ctx.check_async_request();
        let key = Key::File(self.spec.dialog.0);
        self.ctx.submit_dialog(TxOp::ShowFileDialog(self.spec));
        self.ctx.reply(key, Pending::File)
    }
}

#[must_use]
pub struct SaveFutureRef<'a> {
    ctx: &'a AppCtx,
    spec: SaveDialogSpec,
}

impl SaveFutureRef<'_> {
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }
    pub fn filter(mut self, label: impl Into<String>, extensions: impl Into<String>) -> Self {
        self.spec.filters.push((label.into(), extensions.into()));
        self
    }
}

impl<'a> IntoFuture for SaveFutureRef<'a> {
    type Output = Option<PickedFile>;
    type IntoFuture = DialogFuture<'a, Option<PickedFile>>;
    fn into_future(self) -> Self::IntoFuture {
        self.ctx.check_async_request();
        let key = Key::File(self.spec.dialog.0);
        self.ctx.submit_dialog(TxOp::ShowSaveDialog(self.spec));
        self.ctx.reply(key, Pending::Save)
    }
}

#[must_use]
pub struct ClipboardFutureRef<'a> {
    ctx: &'a AppCtx,
    request: u64,
    accepting: Vec<String>,
}

impl ClipboardFutureRef<'_> {
    pub fn text(mut self) -> Self {
        self.accepting.push("text".into());
        self
    }
    pub fn html(mut self) -> Self {
        self.accepting.push("html".into());
        self
    }
    pub fn image(mut self) -> Self {
        self.accepting.push("image".into());
        self
    }
    pub fn files(mut self) -> Self {
        self.accepting.push("files".into());
        self
    }
    pub fn custom(mut self, id: impl Into<String>) -> Self {
        self.accepting.push(id.into());
        self
    }
}

impl<'a> IntoFuture for ClipboardFutureRef<'a> {
    type Output = Option<Representation>;
    type IntoFuture = DialogFuture<'a, Option<Representation>>;
    fn into_future(self) -> Self::IntoFuture {
        self.ctx.check_async_request();
        self.ctx.submit_dialog(TxOp::ReadClipboard {
            request: self.request,
            accepting: self.accepting.join(" "),
        });
        self.ctx
            .reply(Key::Clipboard(self.request), Pending::Clipboard)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Transaction, WidgetId};
    use std::rc::Rc;
    use std::sync::mpsc::{self, Receiver};
    use std::time::Duration;

    fn context() -> (AppCtx, Receiver<Transaction>, Sender<Inbox>) {
        let (send, receive) = mpsc::channel();
        let (transactions, batches) = mpsc::channel();
        (
            AppCtx::new(receive, transactions, send.clone()),
            batches,
            send,
        )
    }

    fn clicked(send: &Sender<Inbox>) {
        send.send(Inbox::Occ(Occurrence::ButtonClicked { id: WidgetId(99) }))
            .unwrap();
    }

    fn refused(body: impl FnOnce(), needle: &str) {
        let failure = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body))
            .expect_err("missing refusal");
        let message = failure
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| failure.downcast_ref::<&str>().copied())
            .unwrap();
        assert!(message.contains(needle), "{message}");
    }

    #[test]
    fn async_tasks_foreign_wake_raw_and_typed_loops() {
        for typed in [false, true] {
            let (ctx, batches, send) = context();
            let tasks = ctx.tasks();
            let (waker_tx, waker_rx) = mpsc::channel::<Waker>();
            let ready = Arc::new(AtomicBool::new(false));
            let foreign_ready = ready.clone();
            let worker = std::thread::spawn(move || {
                let wake = waker_rx.recv_timeout(Duration::from_secs(3)).unwrap();
                foreign_ready.store(true, Ordering::Release);
                wake.wake();
                clicked(&send);
            });
            let count = Rc::new(Cell::new(0));
            let observed = count.clone();
            let thread = std::thread::current().id();
            tasks.spawn(async move |app| {
                assert_eq!(app.open_transactions.get(), 0);
                std::future::poll_fn(|cx| {
                    if ready.load(Ordering::Acquire) {
                        Poll::Ready(())
                    } else {
                        waker_tx.send(cx.waker().clone()).unwrap();
                        Poll::Pending
                    }
                })
                .await;
                assert_eq!(std::thread::current().id(), thread);
                assert_eq!(app.open_transactions.get(), 0);
                observed.set(observed.get() + 1);
            });
            if typed {
                let messages = Messages::new();
                messages.on_click(WidgetId(99), 7);
                assert_eq!(tasks.next(&messages), Some(7));
            } else {
                assert!(matches!(
                    tasks.next_occurrence(),
                    Occurrence::ButtonClicked { .. }
                ));
            }
            worker.join().unwrap();
            assert_eq!(count.get(), 1);
            assert!(
                batches.try_recv().is_err(),
                "task execution opened an ambient transaction"
            );
        }
    }

    #[test]
    fn async_tasks_all_dialog_answers_retire_before_resume() {
        let (ctx, batches, send) = context();
        let tasks = ctx.tasks();
        let worker = std::thread::spawn(move || {
            for index in 0..5 {
                let batch = batches.recv_timeout(Duration::from_secs(3)).unwrap();
                let occurrence = match (&batch[..], index) {
                    ([TxOp::ShowAlert(spec)], 0) => {
                        assert_eq!(spec.cancel, "Keep");
                        Occurrence::AlertResult {
                            alert: spec.alert,
                            choice: AlertChoice::Action(1),
                        }
                    }
                    ([TxOp::ShowFileDialog(spec)], 1 | 2) => {
                        assert_eq!(spec.multiple, index == 2);
                        assert_eq!(spec.filters, vec![("Text".into(), "txt".into())]);
                        Occurrence::FileDialogResult {
                            dialog: spec.dialog,
                            files: vec![],
                        }
                    }
                    ([TxOp::ShowSaveDialog(spec)], 3) => {
                        assert_eq!(spec.suggested_name, "note.txt");
                        Occurrence::FileDialogResult {
                            dialog: spec.dialog,
                            files: vec![],
                        }
                    }
                    ([TxOp::ReadClipboard { request, accepting }], 4) => {
                        assert_eq!(accepting, "text html");
                        Occurrence::ClipboardResult {
                            request: *request,
                            clip: None,
                        }
                    }
                    _ => panic!("unexpected request {index}: {batch:?}"),
                };
                send.send(Inbox::Occ(occurrence)).unwrap();
            }
        });
        let done = Rc::new(Cell::new(false));
        let observed = done.clone();
        tasks.spawn(async move |app| {
            assert_eq!(
                app.show_alert()
                    .cancel("Keep")
                    .action("A")
                    .action("B")
                    .await,
                AlertChoice::Action(1)
            );
            assert!(app.replies.borrow().alert.is_none());
            assert!(app.pick_file().filter("Text", "txt").await.is_empty());
            assert!(app.pick_files().filter("Text", "txt").await.is_empty());
            assert!(app.save_file("note.txt").await.is_none());
            assert!(app.read_clipboard().text().html().await.is_none());
            assert!(app.replies.borrow().pending.is_empty());
            observed.set(true);
            clicked(&app.wake);
        });
        assert!(matches!(
            tasks.next_occurrence(),
            Occurrence::ButtonClicked { .. }
        ));
        worker.join().unwrap();
        assert!(done.get());
        assert!(tasks.tasks.borrow().is_empty());
    }

    #[test]
    fn async_tasks_panic_rolls_back_only_failing_scope() {
        let (ctx, batches, send) = context();
        let rows = ctx.apply(|tx| tx.collection::<String>());
        batches.try_recv().unwrap();
        let tasks = ctx.tasks();
        let task_rows = rows.clone();
        tasks.spawn(async move |app| {
            app.apply(|tx| tx.insert(&task_rows, "kept", "committed".to_owned()));
            let _ = app.read_clipboard().text().await;
            app.apply(|tx| {
                tx.insert(&task_rows, "lost", "rolled back".to_owned());
                panic!("deliberate resumed scope failure");
            });
        });
        let worker = std::thread::spawn(move || {
            batches.recv_timeout(Duration::from_secs(3)).unwrap();
            let request = batches.recv_timeout(Duration::from_secs(3)).unwrap();
            let [TxOp::ReadClipboard { request, .. }] = request.as_slice() else {
                panic!("missing read")
            };
            send.send(Inbox::Occ(Occurrence::ClipboardResult {
                request: *request,
                clip: None,
            }))
            .unwrap();
            clicked(&send);
        });
        tasks.next_occurrence();
        worker.join().unwrap();
        assert_eq!(ctx.open_transactions.get(), 0);
        assert_eq!(ctx.apply(|tx| tx.items(&rows).len()), 1);
        assert!(tasks.tasks.borrow().is_empty());
    }

    #[test]
    fn async_tasks_failures_do_not_discard_sibling_jobs() {
        let (ctx, _batches, send) = context();
        let tasks = ctx.tasks();
        tasks.spawn(async |_| -> () {
            panic!("deliberate initial task failure");
        });
        tasks
            .spawn(async |_| -> Result<(), &'static str> { Err("deliberate task result failure") });
        let done = Rc::new(Cell::new(false));
        let observed = done.clone();
        tasks.spawn(async move |_| {
            observed.set(true);
        });
        clicked(&send);
        tasks.next_occurrence();
        assert!(done.get());
        assert!(tasks.tasks.borrow().is_empty());
    }

    #[test]
    fn async_tasks_shutdown_and_drop_release_suspended_state() {
        for shutdown in [false, true] {
            let (ctx, batches, send) = context();
            let tasks = ctx.tasks();
            let state = Rc::new(());
            let weak = Rc::downgrade(&state);
            tasks.spawn(async move |app| {
                let _state = state;
                app.show_alert().cancel("Keep").await;
            });
            clicked(&send);
            tasks.next_occurrence();
            batches.try_recv().unwrap();
            assert!(weak.upgrade().is_some());
            let stale = tasks.tasks.borrow().values().next().unwrap().wake.clone();
            if shutdown {
                send.send(Inbox::Occ(Occurrence::Shutdown)).unwrap();
                assert!(matches!(tasks.next_occurrence(), Occurrence::Shutdown));
                assert!(weak.upgrade().is_none());
                refused(|| tasks.spawn(async |_| {}), "closed task scope");
            }
            drop(tasks);
            assert!(weak.upgrade().is_none());
            assert!(ctx.replies.borrow().pending.is_empty());
            assert!(!ctx.tasks_active.get());
            stale.wake_by_ref();
            assert!(stale.ready.queue.lock().unwrap().is_none());
        }
    }

    #[test]
    fn async_tasks_loop_and_scope_reentry_refused() {
        let (ctx, _batches, send) = context();
        let tasks = ctx.tasks();
        refused(
            || {
                ctx.tasks();
            },
            "only one task scope",
        );
        refused(
            || {
                ctx.next();
            },
            "use tasks.next",
        );
        let visited = Rc::new(Cell::new(false));
        let observed = visited.clone();
        tasks.spawn(async move |app| {
            clicked(&app.wake);
            refused(
                || {
                    app.next_with(|| {});
                },
                "cannot reenter the occurrence loop",
            );
            assert!(app.loop_active.get());
            observed.set(true);
        });
        clicked(&send);
        tasks.next_occurrence();
        assert!(visited.get());
        assert!(!ctx.loop_active.get());
        refused(
            || {
                ctx.apply(|_| tasks.next_occurrence());
            },
            "open transaction",
        );
        assert_eq!(ctx.open_transactions.get(), 0);
    }

    #[test]
    fn async_tasks_callback_and_future_share_slots_and_abort_cleanup() {
        let (ctx, _batches, send) = context();
        let tasks = ctx.tasks();
        let id = ctx.apply(|tx| tx.show_alert().cancel("Keep").show());
        refused(
            || {
                ctx.show_alert().cancel("Keep").into_future();
            },
            "alert is already live",
        );
        send.send(Inbox::Occ(Occurrence::AlertResult {
            alert: id,
            choice: AlertChoice::Cancel,
        }))
        .unwrap();
        assert!(matches!(
            tasks.next_occurrence(),
            Occurrence::AlertResult { .. }
        ));
        let future = ctx.show_alert().cancel("Keep").into_future();
        refused(
            || {
                ctx.apply(|tx| tx.show_alert().cancel("Keep").show());
            },
            "alert is already live",
        );
        drop(future);
        assert!(ctx.replies.borrow().pending.is_empty());
        refused(
            || {
                ctx.show_alert().cancel("Keep").into_future();
            },
            "alert is already live",
        );
        for save in [false, true] {
            refused(
                || {
                    ctx.apply(|tx| {
                        if save {
                            tx.save_file("note.txt").show();
                        } else {
                            tx.pick_file().show();
                        }
                        panic!("aborted dialog scope");
                    });
                },
                "aborted dialog scope",
            );
            assert!(ctx.replies.borrow().file.is_none());
        }
        let future = ctx.pick_files().into_future();
        refused(
            || {
                ctx.save_file("note.txt").into_future();
            },
            "file dialog is already live",
        );
        refused(
            || {
                ctx.apply(|tx| tx.pick_file().show());
            },
            "file dialog is already live",
        );
        drop(future);
    }

    #[test]
    fn async_tasks_requests_refuse_scopeless_ambient_and_closed_transport() {
        let (ctx, batches, _send) = context();
        refused(
            || {
                ctx.pick_file().into_future();
            },
            "live task scope",
        );
        let tasks = ctx.tasks();
        refused(
            || {
                ctx.apply(|_| {
                    ctx.pick_file().into_future();
                });
            },
            "outside apply",
        );
        assert!(ctx.replies.borrow().pending.is_empty());
        assert!(ctx.replies.borrow().file.is_none());
        assert!(batches.try_recv().is_err());
        drop(batches);
        refused(
            || {
                ctx.pick_file().into_future();
            },
            "transport closed",
        );
        assert!(ctx.replies.borrow().pending.is_empty());
        assert!(ctx.replies.borrow().file.is_none());
        assert!(matches!(tasks.next_occurrence(), Occurrence::Shutdown));
    }

    #[test]
    fn async_tasks_self_wakes_are_deduplicated() {
        let (ctx, _batches, send) = context();
        let tasks = ctx.tasks();
        let polls = Rc::new(Cell::new(0));
        let observed = polls.clone();
        let ready = tasks.ready.clone();
        tasks.spawn(async move |_| {
            std::future::poll_fn(|cx| {
                observed.set(observed.get() + 1);
                if observed.get() == 1 {
                    for _ in 0..100 {
                        cx.waker().wake_by_ref();
                    }
                    let queued = ready.queue.lock().unwrap().as_ref().unwrap().len();
                    assert_eq!(queued, 1);
                    Poll::Pending
                } else {
                    Poll::Ready(())
                }
            })
            .await;
        });
        clicked(&send);
        tasks.next_occurrence();
        assert_eq!(polls.get(), 2);
        assert!(tasks.tasks.borrow().is_empty());
    }

    #[test]
    fn async_tasks_payloads_and_one_shot_delivery() {
        let (ctx, _batches, _send) = context();
        let _tasks = ctx.tasks();
        let mut cx = Context::from_waker(Waker::noop());
        let mut alert = Box::pin(ctx.show_alert().cancel("Keep").into_future());
        let id = ctx.replies.borrow().alert.unwrap();
        assert!(alert.as_mut().poll(&mut cx).is_pending());
        let occurrence = Occurrence::AlertResult {
            alert: crate::AlertId(id),
            choice: AlertChoice::Cancel,
        };
        assert!(ctx.resolve_reply(&occurrence));
        assert!(!ctx.resolve_reply(&occurrence));
        assert_eq!(
            alert.as_mut().poll(&mut cx),
            Poll::Ready(AlertChoice::Cancel)
        );
        let file = PickedFile {
            handle: crate::PickedId(77),
            name: "chosen".into(),
            local_path: String::new(),
        };
        let mut picked = Box::pin(ctx.pick_files().into_future());
        let id = ctx.replies.borrow().file.unwrap();
        let occurrence = Occurrence::FileDialogResult {
            dialog: crate::FileDialogId(id),
            files: vec![file.clone()],
        };
        assert!(ctx.resolve_reply(&occurrence));
        assert!(!ctx.resolve_reply(&occurrence));
        assert_eq!(
            picked.as_mut().poll(&mut cx),
            Poll::Ready(vec![file.clone()])
        );
        assert!(ctx.replies.borrow().file.is_none());
        let mut saved = Box::pin(ctx.save_file("chosen").into_future());
        let id = ctx.replies.borrow().file.unwrap();
        assert!(ctx.resolve_reply(&Occurrence::FileDialogResult {
            dialog: crate::FileDialogId(id),
            files: vec![file.clone()]
        }));
        assert_eq!(saved.as_mut().poll(&mut cx), Poll::Ready(Some(file)));
        let mut clip = Box::pin(ctx.read_clipboard().text().into_future());
        let Key::Clipboard(id) = clip.key else {
            unreachable!()
        };
        assert!(ctx.resolve_reply(&Occurrence::ClipboardResult {
            request: id,
            clip: Some(Representation::Text("copied".into()))
        }));
        assert_eq!(
            clip.as_mut().poll(&mut cx),
            Poll::Ready(Some(Representation::Text("copied".into())))
        );
        assert!(ctx.replies.borrow().pending.is_empty());
    }

    #[test]
    fn async_tasks_closed_transport_discards_unstarted_jobs() {
        let (ctx, batches, _send) = context();
        let tasks = ctx.tasks();
        let ran = Rc::new(Cell::new(false));
        let observed = ran.clone();
        tasks.spawn(async move |_| {
            observed.set(true);
        });
        let posted = Arc::new(AtomicBool::new(false));
        let observed = posted.clone();
        ctx.poster().post(move |_| {
            observed.store(true, Ordering::Release);
        });
        drop(batches);
        refused(
            || {
                ctx.read_clipboard().text().into_future();
            },
            "transport closed",
        );
        assert!(matches!(tasks.next_occurrence(), Occurrence::Shutdown));
        assert!(!ran.get());
        assert!(!posted.load(Ordering::Acquire));
        assert!(tasks.tasks.borrow().is_empty());
    }

    #[test]
    fn async_tasks_external_future_closes_without_cancelling_native_slot() {
        let (ctx, _batches, send) = context();
        let tasks = ctx.tasks();
        let mut future = Box::pin(ctx.show_alert().cancel("Keep").into_future());
        let id = ctx.replies.borrow().alert.unwrap();
        drop(tasks);
        refused(
            || {
                let _ = future
                    .as_mut()
                    .poll(&mut Context::from_waker(Waker::noop()));
            },
            "scope closed",
        );
        drop(future);
        assert_eq!(ctx.replies.borrow().alert, Some(id));
        send.send(Inbox::Occ(Occurrence::AlertResult {
            alert: crate::AlertId(id),
            choice: AlertChoice::Cancel,
        }))
        .unwrap();
        ctx.next();
        assert!(ctx.replies.borrow().alert.is_none());
    }

    #[test]
    fn async_tasks_panic_after_await_outside_scope_keeps_completed_write() {
        let (ctx, batches, send) = context();
        let rows = ctx.apply(|tx| tx.collection::<String>());
        batches.try_recv().unwrap();
        let tasks = ctx.tasks();
        let task_rows = rows.clone();
        tasks.spawn(async move |app| -> () {
            app.read_clipboard().text().await;
            app.apply(|tx| tx.insert(&task_rows, "kept", "committed".to_owned()));
            panic!("deliberate failure outside scope");
        });
        let worker = std::thread::spawn(move || {
            let request = batches.recv_timeout(Duration::from_secs(3)).unwrap();
            let [TxOp::ReadClipboard { request, .. }] = request.as_slice() else {
                panic!("missing read")
            };
            send.send(Inbox::Occ(Occurrence::ClipboardResult {
                request: *request,
                clip: None,
            }))
            .unwrap();
            clicked(&send);
        });
        tasks.next_occurrence();
        worker.join().unwrap();
        assert_eq!(ctx.apply(|tx| tx.items(&rows).len()), 1);
        assert_eq!(ctx.open_transactions.get(), 0);
    }
}
