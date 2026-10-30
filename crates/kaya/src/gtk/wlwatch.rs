//! What this client's own wayland objects heard: a data device and a keyboard
//! of its own on GDK's connection, dispatched on a queue of their own, so a
//! clipboard seed that expires can say whether the compositor handed this
//! client the new selection, with which types, and whether this client held
//! the seat's keyboard focus (docs/deferred.md, DEFECT clipboard-java-wayland).
//! libwayland-client is reached through dlsym: GTK has it loaded, and its
//! protocol helpers are header inlines over wl_proxy_marshal_flags. Every
//! object is bound at version 1, so each listener lists version 1's events.

use std::ffi::{c_char, c_void, CStr};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

#[repr(C)]
struct WlInterface {
    name: *const c_char,
    version: i32,
    method_count: i32,
    methods: *const c_void,
    event_count: i32,
    events: *const c_void,
}

type Proxy = *mut c_void;

struct Api {
    create_queue: unsafe extern "C" fn(Proxy) -> *mut c_void,
    create_wrapper: unsafe extern "C" fn(Proxy) -> Proxy,
    set_queue: unsafe extern "C" fn(Proxy, *mut c_void),
    add_listener: unsafe extern "C" fn(Proxy, *const c_void, *mut c_void) -> i32,
    get_id: unsafe extern "C" fn(Proxy) -> u32,
    marshal: unsafe extern "C" fn(Proxy, u32, *const WlInterface, u32, u32, ...) -> Proxy,
    roundtrip_queue: unsafe extern "C" fn(Proxy, *mut c_void) -> i32,
    dispatch_pending: unsafe extern "C" fn(Proxy, *mut c_void) -> i32,
    registry: *const WlInterface,
    seat: *const WlInterface,
    manager: *const WlInterface,
    device: *const WlInterface,
    keyboard: *const WlInterface,
}

unsafe impl Send for Api {}
unsafe impl Sync for Api {}

fn sym(name: &CStr) -> Result<*mut c_void, String> {
    let at = unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()) };
    if at.is_null() {
        Err(format!("libwayland-client's {} is not loaded in this process", name.to_string_lossy()))
    } else {
        Ok(at)
    }
}

impl Api {
    fn load() -> Result<Api, String> {
        unsafe {
            Ok(Api {
                create_queue: std::mem::transmute::<*mut c_void, _>(sym(c"wl_display_create_queue")?),
                create_wrapper: std::mem::transmute::<*mut c_void, _>(sym(c"wl_proxy_create_wrapper")?),
                set_queue: std::mem::transmute::<*mut c_void, _>(sym(c"wl_proxy_set_queue")?),
                add_listener: std::mem::transmute::<*mut c_void, _>(sym(c"wl_proxy_add_listener")?),
                get_id: std::mem::transmute::<*mut c_void, _>(sym(c"wl_proxy_get_id")?),
                marshal: std::mem::transmute::<*mut c_void, _>(sym(c"wl_proxy_marshal_flags")?),
                roundtrip_queue: std::mem::transmute::<*mut c_void, _>(sym(c"wl_display_roundtrip_queue")?),
                dispatch_pending: std::mem::transmute::<*mut c_void, _>(sym(c"wl_display_dispatch_queue_pending")?),
                registry: sym(c"wl_registry_interface")? as *const WlInterface,
                seat: sym(c"wl_seat_interface")? as *const WlInterface,
                manager: sym(c"wl_data_device_manager_interface")? as *const WlInterface,
                device: sym(c"wl_data_device_interface")? as *const WlInterface,
                keyboard: sym(c"wl_keyboard_interface")? as *const WlInterface,
            })
        }
    }
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

fn api() -> Option<&'static Api> {
    API.get().and_then(|a| a.as_ref().ok())
}

fn id_of(p: Proxy) -> u32 {
    match api() {
        Some(api) if !p.is_null() => unsafe { (api.get_id)(p) },
        _ => 0,
    }
}

/// Everything the objects heard, in order, and each offer's types.
#[derive(Default)]
struct Heard {
    events: Vec<(Instant, String)>,
    offers: Vec<(u32, Vec<String>)>,
    selection: Option<Option<u32>>,
    focus: Option<(u32, bool)>,
    capabilities: Option<u32>,
    globals: Vec<(u32, String)>,
}

static HEARD: Mutex<Option<Heard>> = Mutex::new(None);

fn heard<T>(f: impl FnOnce(&mut Heard) -> T) -> T {
    let mut h = HEARD.lock().unwrap_or_else(|e| e.into_inner());
    f(h.get_or_insert_with(Heard::default))
}

unsafe extern "C" fn registry_global(_: *mut c_void, _: Proxy, name: u32, iface: *const c_char, _: u32) {
    let iface = unsafe { CStr::from_ptr(iface) }.to_string_lossy().into_owned();
    heard(|h| h.globals.push((name, iface)));
}
unsafe extern "C" fn registry_remove(_: *mut c_void, _: Proxy, _: u32) {}

#[repr(C)]
struct RegistryListener {
    global: unsafe extern "C" fn(*mut c_void, Proxy, u32, *const c_char, u32),
    remove: unsafe extern "C" fn(*mut c_void, Proxy, u32),
}
static REGISTRY: RegistryListener = RegistryListener { global: registry_global, remove: registry_remove };

/// The seat this watcher bound, and whether its keyboard is live: a
/// wl_keyboard asked for while the seat had no keyboard heard no enter after
/// the seat gained one (measured, a forced red under wtype), so a new one is
/// asked for each time the seat gains the capability.
static SEAT_PROXY: std::sync::atomic::AtomicPtr<c_void> = std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());
static KEYBOARD_LIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

unsafe extern "C" fn seat_caps(_: *mut c_void, _: Proxy, caps: u32) {
    use std::sync::atomic::Ordering::SeqCst;
    if caps & 2 == 0 {
        KEYBOARD_LIVE.store(false, SeqCst);
    } else if !KEYBOARD_LIVE.swap(true, SeqCst) {
        let seat = SEAT_PROXY.load(SeqCst);
        if let (Some(api), false) = (api(), seat.is_null()) {
            unsafe {
                let keyboard =
                    (api.marshal)(seat, WL_SEAT_GET_KEYBOARD, api.keyboard, 1, 0, std::ptr::null_mut::<c_void>());
                (api.add_listener)(keyboard, &KEYBOARD as *const KeyboardListener as *const c_void, std::ptr::null_mut());
            }
        }
    }
    heard(|h| {
        h.capabilities = Some(caps);
        h.events.push((Instant::now(), format!("seat capabilities {}", capability_words(caps))));
    });
}

/// wl_seat's capability bits in words: pointer 1, keyboard 2, touch 4.
fn capability_words(caps: u32) -> String {
    let words: Vec<&str> =
        [(1, "pointer"), (2, "keyboard"), (4, "touch")].iter().filter(|(bit, _)| caps & bit != 0).map(|(_, w)| *w).collect();
    if words.is_empty() { "none".to_owned() } else { words.join("+") }
}

#[repr(C)]
struct SeatListener {
    capabilities: unsafe extern "C" fn(*mut c_void, Proxy, u32),
}
static SEAT: SeatListener = SeatListener { capabilities: seat_caps };

unsafe extern "C" fn offer_mime(_: *mut c_void, offer: Proxy, mime: *const c_char) {
    let id = id_of(offer);
    let mime = unsafe { CStr::from_ptr(mime) }.to_string_lossy().into_owned();
    heard(|h| {
        if let Some((_, types)) = h.offers.iter_mut().rev().find(|(o, _)| *o == id) {
            types.push(mime);
        }
    });
}

#[repr(C)]
struct OfferListener {
    offer: unsafe extern "C" fn(*mut c_void, Proxy, *const c_char),
}
static OFFER: OfferListener = OfferListener { offer: offer_mime };

unsafe extern "C" fn device_offer(_: *mut c_void, _: Proxy, offer: Proxy) {
    let id = id_of(offer);
    if let Some(api) = api() {
        unsafe { (api.add_listener)(offer, &OFFER as *const OfferListener as *const c_void, std::ptr::null_mut()) };
    }
    heard(|h| {
        h.offers.push((id, Vec::new()));
        h.events.push((Instant::now(), format!("data_offer #{id}")));
    });
}
unsafe extern "C" fn device_enter(_: *mut c_void, _: Proxy, _: u32, _: Proxy, _: i32, _: i32, _: Proxy) {}
unsafe extern "C" fn device_leave(_: *mut c_void, _: Proxy) {}
unsafe extern "C" fn device_motion(_: *mut c_void, _: Proxy, _: u32, _: i32, _: i32) {}
unsafe extern "C" fn device_drop(_: *mut c_void, _: Proxy) {}
unsafe extern "C" fn device_selection(_: *mut c_void, _: Proxy, offer: Proxy) {
    let id = (!offer.is_null()).then(|| id_of(offer));
    heard(|h| {
        h.selection = Some(id);
        h.events.push((
            Instant::now(),
            id.map_or_else(|| "selection cleared".to_owned(), |id| format!("selection #{id}")),
        ));
    });
}

#[repr(C)]
struct DeviceListener {
    data_offer: unsafe extern "C" fn(*mut c_void, Proxy, Proxy),
    enter: unsafe extern "C" fn(*mut c_void, Proxy, u32, Proxy, i32, i32, Proxy),
    leave: unsafe extern "C" fn(*mut c_void, Proxy),
    motion: unsafe extern "C" fn(*mut c_void, Proxy, u32, i32, i32),
    drop: unsafe extern "C" fn(*mut c_void, Proxy),
    selection: unsafe extern "C" fn(*mut c_void, Proxy, Proxy),
}
static DEVICE: DeviceListener = DeviceListener {
    data_offer: device_offer,
    enter: device_enter,
    leave: device_leave,
    motion: device_motion,
    drop: device_drop,
    selection: device_selection,
};

unsafe extern "C" fn key_map(_: *mut c_void, _: Proxy, _: u32, fd: i32, _: u32) {
    unsafe { libc::close(fd) };
}
unsafe extern "C" fn key_enter(_: *mut c_void, _: Proxy, _: u32, surface: Proxy, _: *mut c_void) {
    let id = id_of(surface);
    heard(|h| {
        h.focus = Some((id, true));
        h.events.push((Instant::now(), format!("keyboard enter surface #{id}")));
    });
}
unsafe extern "C" fn key_leave(_: *mut c_void, _: Proxy, _: u32, surface: Proxy) {
    let id = id_of(surface);
    heard(|h| {
        h.focus = Some((id, false));
        h.events.push((Instant::now(), format!("keyboard leave surface #{id}")));
    });
}
unsafe extern "C" fn key_key(_: *mut c_void, _: Proxy, _: u32, _: u32, _: u32, _: u32) {}
unsafe extern "C" fn key_mods(_: *mut c_void, _: Proxy, _: u32, _: u32, _: u32, _: u32, _: u32) {}

#[repr(C)]
struct KeyboardListener {
    keymap: unsafe extern "C" fn(*mut c_void, Proxy, u32, i32, u32),
    enter: unsafe extern "C" fn(*mut c_void, Proxy, u32, Proxy, *mut c_void),
    leave: unsafe extern "C" fn(*mut c_void, Proxy, u32, Proxy),
    key: unsafe extern "C" fn(*mut c_void, Proxy, u32, u32, u32, u32),
    modifiers: unsafe extern "C" fn(*mut c_void, Proxy, u32, u32, u32, u32, u32),
}
static KEYBOARD: KeyboardListener =
    KeyboardListener { keymap: key_map, enter: key_enter, leave: key_leave, key: key_key, modifiers: key_mods };

/// GDK's connection and the queue this watcher's objects live on.
struct Queue {
    display: Proxy,
    queue: *mut c_void,
}
unsafe impl Send for Queue {}

static WATCH: Mutex<Option<Result<Queue, String>>> = Mutex::new(None);

const WL_DISPLAY_GET_REGISTRY: u32 = 1;
const WL_REGISTRY_BIND: u32 = 0;
const WL_SEAT_GET_KEYBOARD: u32 = 1;
const WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE: u32 = 1;

fn begin(display: Proxy) -> Result<Queue, String> {
    let api = API.get_or_init(Api::load).as_ref().map_err(Clone::clone)?;
    unsafe {
        let queue = (api.create_queue)(display);
        let wrapper = (api.create_wrapper)(display);
        if queue.is_null() || wrapper.is_null() {
            return Err("libwayland made no event queue or display wrapper".to_owned());
        }
        (api.set_queue)(wrapper, queue);
        let registry =
            (api.marshal)(wrapper, WL_DISPLAY_GET_REGISTRY, api.registry, 1, 0, std::ptr::null_mut::<c_void>());
        (api.add_listener)(registry, &REGISTRY as *const RegistryListener as *const c_void, std::ptr::null_mut());
        if (api.roundtrip_queue)(display, queue) < 0 {
            return Err("the registry's roundtrip failed".to_owned());
        }
        let globals = heard(|h| h.globals.clone());
        let find = |iface: &str| globals.iter().find(|(_, i)| i == iface).map(|(n, _)| *n);
        let bind = |name: u32, iface: *const WlInterface| {
            (api.marshal)(registry, WL_REGISTRY_BIND, iface, 1, 0, name, (*iface).name, 1u32, std::ptr::null_mut::<c_void>())
        };
        let (Some(seat_name), Some(manager_name)) = (find("wl_seat"), find("wl_data_device_manager")) else {
            return Err(format!("the registry lists no wl_seat or no wl_data_device_manager among {} globals", globals.len()));
        };
        let seat = bind(seat_name, api.seat);
        SEAT_PROXY.store(seat, std::sync::atomic::Ordering::SeqCst);
        (api.add_listener)(seat, &SEAT as *const SeatListener as *const c_void, std::ptr::null_mut());
        let manager = bind(manager_name, api.manager);
        let device = (api.marshal)(
            manager,
            WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
            api.device,
            1,
            0,
            std::ptr::null_mut::<c_void>(),
            seat,
        );
        (api.add_listener)(device, &DEVICE as *const DeviceListener as *const c_void, std::ptr::null_mut());
        if (api.roundtrip_queue)(display, queue) < 0 {
            return Err("the devices' roundtrip failed".to_owned());
        }
        Ok(Queue { display, queue })
    }
}

/// Start listening on GDK's connection, once per process; what came of the
/// start is kept and said by every report.
pub(super) fn start(display: Proxy) {
    let mut watch = WATCH.lock().unwrap_or_else(|e| e.into_inner());
    if watch.is_none() {
        *watch = Some(begin(display));
    }
}

/// Where the events stand now: a mark a later report reads from.
pub(super) fn mark() -> usize {
    pump();
    heard(|h| h.events.len())
}

/// Dispatch what GDK's reads have queued for these objects, so each event's
/// time is within a seed round of its arrival.
pub(super) fn pump() {
    let watch = WATCH.lock().unwrap_or_else(|e| e.into_inner());
    if let (Some(Ok(q)), Some(api)) = (watch.as_ref(), api()) {
        unsafe { (api.dispatch_pending)(q.display, q.queue) };
    }
}

/// What this client's own objects heard since `since`: each new offer with
/// its types, the selection the compositor last named, and whether this
/// client's keyboard holds the seat's focus (a wl_keyboard is entered only
/// on its own client's surfaces).
pub(super) fn report(since: usize, started: Instant) -> String {
    pump();
    let watch = WATCH.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(Err(why)) = watch.as_ref() {
        return format!("wayland: this client's watcher did not start: {why}");
    }
    heard(|h| {
        let new: Vec<String> = h.events[since.min(h.events.len())..]
            .iter()
            .map(|(at, what)| {
                match at.checked_duration_since(started) {
                    Some(after) => format!("+{}ms {what}", after.as_millis()),
                    None => format!("-{}ms {what}", started.duration_since(*at).as_millis()),
                }
            })
            .collect();
        let offers: Vec<u32> = h.events[since.min(h.events.len())..]
            .iter()
            .filter_map(|(_, what)| what.strip_prefix("data_offer #").and_then(|n| n.parse().ok()))
            .collect();
        let offered = if offers.is_empty() {
            "NO data_offer reached this client since the write".to_owned()
        } else {
            offers
                .iter()
                .map(|id| {
                    let types = h.offers.iter().rev().find(|(o, _)| o == id).map(|(_, t)| t.join(",")).unwrap_or_default();
                    format!("data_offer #{id} [{types}]")
                })
                .collect::<Vec<_>>()
                .join(" ")
        };
        let selection = match h.selection {
            None => "no selection event ever".to_owned(),
            Some(None) => "the selection is cleared".to_owned(),
            Some(Some(id)) => {
                let types = h.offers.iter().rev().find(|(o, _)| *o == id).map(|(_, t)| t.join(",")).unwrap_or_default();
                format!("the selection names offer #{id} [{types}]")
            }
        };
        let seat = match h.capabilities {
            None => "the seat named no capabilities".to_owned(),
            Some(caps) => format!("the seat offers {}", capability_words(caps)),
        };
        let focus = match h.focus {
            None => format!("this client's keyboard heard no enter ({seat})"),
            Some((s, true)) => format!("this client's keyboard holds the seat's focus (surface #{s}; {seat})"),
            Some((s, false)) => format!("this client's keyboard LEFT surface #{s} and holds no focus ({seat})"),
        };
        format!("wayland: {offered}; {selection}; {focus}; heard since the write: [{}]", new.join(", "))
    })
}
