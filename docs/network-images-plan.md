# Images from the network: the design pass (2026-10-13)

Status: RULED 2026-10-13 (the maintainer: "im okay with those rulings"), N1-N17 as
recommended (§8). DEPTH BUILT 2026-10-13 on the mac and iOS with the Rust
binding (docs/deferred.md's BUILD entry; §7 records what it measured);
BREADTH BUILT 2026-10-13 on GTK, WinUI and Compose and in all nine bindings
with the C floor (§7's breadth block); the media player's art (N17) and the
review page are open. The roadmap
card (docs/roadmap/editorial.toml, "Images from the network") asks for "a
remote image source with a cache, a placeholder while loading and a stated
failure, in both zones so a table row's art loads per row", and names the
media player demo's album art as the forcing case. The maintainer reframed it
the same day, and this pass starts from his words:

> network images sounds good, but that sounds like something the guest
> language would add, with affordances in the toolkit for loading/failure
> states based on how background work is done.

and, on the cache:

> we don't want an http client inside kaya yeah. not sure about the image
> cache. worth looking at what other toolkits do.

So the HTTP client is out (N1 records it), and the cache is its own ruling
(N10) with the survey behind it in §0. The safe-area, toast and expander
plans (docs/safe-area-plan.md, docs/toast-plan.md, docs/expander-plan.md) are
the shape of this one; docs/background-work-plan.md and
docs/async-dialogs-plan.md are what it composes with; docs/media-plan.md is
the media player it serves.

Words used in this file, each as the field uses it:

- To DECODE an image is to turn its file bytes (a JPEG or PNG as it came over
  the wire, the ENCODED form) into a grid of pixels the screen can draw (the
  DECODED form, also called a bitmap). A 600x600 picture is about 140 KB
  encoded and 1.44 MB decoded (600 x 600 pixels x 4 bytes).
- To DOWNSAMPLE is to decode straight to a smaller size than the file's own,
  which costs less memory and often less time.
- The UI THREAD (Apple says main thread) is the one thread that draws and
  takes input. Work on it that takes longer than one frame (16.7 ms at 60 Hz,
  8.3 ms at 120 Hz) makes scrolling stutter, which is called JANK.
- The APP THREAD is kaya's other thread, where the guest's handlers run
  (DESIGN.md, Threading model and protocol). A BACKGROUND thread is any third
  thread the guest starts for slow work such as a download.
- A STAMPED COPY is one row's instance of a row template; it exists only
  while its row is in the REALIZED BAND, the viewport plus one viewport each
  side (docs/virtualization-plan.md §1).

## §0: What the platforms offer, and what kaya does today

Rows marked MEASURED were measured for this pass (§7) on the mac and in the
linux lane's image; the probes are in the session scratchpad, `probe/`. The
rest comes from the vendors' documentation, cited at the end of the section.

### What each toolkit does for a network image

| | the widget | phases | where it decodes | decode size | cache | what it does that kaya will not |
|---|---|---|---|---|---|---|
| SwiftUI | `AsyncImage(url:)`, iOS 15 and macOS 12 (above kaya's floors of 16 and 13) | `AsyncImagePhase`: `.empty` (loading), `.success(Image)`, `.failure(Error)`; the default placeholder is a grey fill | URLSession's queue for the bytes; the decode itself is UIKit's and AppKit's: `UIImage(data:)` and `NSImage(data:)` are lazy and decode at first draw, on the main thread. `prepareForDisplay` and `byPreparingForDisplay()` (iOS 15) decode on a background thread | full size unless the app downsamples with ImageIO (`CGImageSourceCreateThumbnailAtIndex`, WWDC18 session 219) | no decoded cache; encoded responses only, through URLSession's HTTP cache, which Apple documents for iOS and macOS 27 and later. A lazy row dropped and re-created downloads the same URL again, and rows just past the first screen report cancelled loads (Apple forums 682498) | takes a URL, does the HTTP, caches through the HTTP layer |
| Compose | none in the toolkit; Android's own page "Load images from the internet" sends the app to Coil or Glide. Coil's `AsyncImage` | `AsyncImagePainter.State`: `Empty`, `Loading`, `Success`, `Error`; `placeholder`, `error`, `fallback` painters | off the main thread (Coil decodes on a background dispatcher) | from the layout's constraints: Coil sizes the request to the box | memory (decoded) and disk (encoded), §0's cache table | the whole pipeline: URL, OkHttp or Ktor, caches, cancellation when the composable leaves |
| GTK 4 | none for URLs; `gdk_texture_new_from_bytes` (4.6) takes bytes. Glycin is GNOME's sandboxed loader set | none | the app's choice: the constructor is documented thread-safe ("use GTask and g_task_run_in_thread() to avoid blocking the main thread"). MEASURED: it runs on a worker thread in the lane image | full size; `GtkPicture` scales at draw | none | nothing: GTK's model is already bytes in |
| libadwaita | `AdwSpinner` (1.6), role progress bar | the HIG: a spinner only for waits over about 3 s, one at a time, never flashed; no skeleton idiom | | | | |
| WinUI 3 | `Image` with a `BitmapImage`; `UriSource` takes an http URL | `ImageOpened` or `ImageFailed`, exactly one fires | on a background thread, straight to GPU memory, when the source is a URI or `SetSourceAsync`; the synchronous `SetSource` loses it | "right-sized decoding" is automatic, lost with synchronous `SetSource`, `Stretch=None`, or an image hidden while it loads; `DecodePixelWidth` and `DecodePixelHeight` set it | decoded images reused per URI; a stream has no identity and is decoded each time | the HTTP through `UriSource`, and the URI-keyed decoded cache |
| Flutter | `Image.network` | `loadingBuilder` (with byte progress, total possibly unknown), `errorBuilder`, `frameBuilder`; `FadeInImage` fades 300 ms out and 700 ms in | the engine's IO thread | `cacheWidth`, `cacheHeight` | `ImageCache`, 1000 images or 100 MB, LRU, every network image cached "regardless of HTTP headers" | URL, HTTP, a global decoded cache |
| React Native | `Image` with a `uri` | `onLoadStart`, `onLoad`, `onError`, `onLoadEnd`, `onProgress`; `defaultSource`. Expo Image adds a BlurHash or ThumbHash `placeholder`, a `transition`, and `recyclingKey`, which blanks a recycled view before the new source arrives | native | native | iOS `cache` prop; Expo's `cachePolicy` | URL, HTTP, caches |

Three phases, everywhere. Every toolkit settles on loading, loaded and failed,
with "no source at all" sometimes a fourth (Coil's `Empty`, Coil's `fallback`).
Byte progress appears only in Flutter and React Native, and Flutter's total is
often unknown.

The recycled-cell problem. On UIKit, Android Views and React Native a row's
view is REUSED for another row, so a download started for row 7 can finish
after its view has become row 40's, and paint row 7's picture on row 40.
Apple's sample code ("Asynchronously Loading Images into Table and Collection
Views") answers it by keeping the result with the ITEM, re-finding the item in
the data snapshot when the download finishes, and reconfiguring whatever cell
shows it now; it never writes into the cell it started from. Expo's
`recyclingKey` exists for the same reason. §1 explains why kaya mostly does
not have this problem and where it still does.

### The image caches, surveyed

The maintainer asked for this table. What is cached, where, keyed by what,
how big, and who owns it:

| | what is cached | where | keyed by | default bound and eviction | under memory pressure | owner | takes the app's own bytes under a key |
|---|---|---|---|---|---|---|---|
| SwiftUI `AsyncImage` | encoded HTTP responses, from iOS and macOS 27 | URLCache, memory and disk | the request | `URLCache.shared`: 512 KB memory, 10 MB disk on iOS (20 MB measured on macOS 26 from a command-line binary); a response over about 5% of the disk size is not stored | the system purges the disk cache while the app is not running | the platform's HTTP layer | no: a URL or a URLRequest only |
| UIKit, AppKit | `UIImage(named:)`: decoded, in "the system caches"; `UIImage(data:)`: nothing | memory | the asset name | the system's; `NSCache`, which apps use for their own, has no limit by default (`totalCostLimit` 0) and evicts in no guaranteed order | purged | the toolkit | `NSCache` takes anything under any key |
| Kingfisher (iOS) | decoded and encoded | memory and disk | the app's key plus the processor | memory a quarter of RAM, entries expire after 300 s; disk unlimited, 7 days, oldest first | memory cleared on a memory warning | a library the app adds | yes, `store(_:forKey:)` |
| SDWebImage (iOS) | decoded and encoded | memory (`NSCache`) and disk | the key, with thumbnail and transform variants as separate keys | memory unlimited; disk unlimited, one week | memory cleared | a library | yes, `storeImageData:forKey:` |
| Nuke (iOS) | decoded and encoded | memory and disk | image id, scale, thumbnail options and processors | memory an LRU of 15% of RAM up to 768 MB, one image at most 10% of it; disk 150 MB | cleared on a warning, mostly emptied in the background | a library | yes, `ImageRequest(id:data:)` |
| Coil 3 (Compose) | decoded and encoded | memory and disk | a data key plus extras; the SIZE is in the key only when the request has transformations, otherwise one entry big enough serves smaller requests | memory 20% of the app's heap limit (15% on low-RAM devices); disk 2% of the disk, 10 to 250 MB | halved on `RUNNING_LOW`, cleared in the background | a library | a `ByteArray` is NOT memory-cached unless the app sets `memoryCacheKey` |
| Glide (Android) | decoded, a bitmap pool, and encoded or resized | memory and disk | model, signature, width, height and transformations | memory two screens of ARGB_8888 pixels, at most 0.4 of the heap; disk 250 MB | trims memory, then the pool | a library | `load(byte[])` is cached nowhere unless the app overrides both and gives a `signature` |
| Flutter | decoded | memory | the `ImageProvider`'s key: URL and scale for `NetworkImage`, plus size for `ResizeImage`, the bytes OBJECT for `MemoryImage` (equal bytes in a new buffer miss) | 1000 images or 100 MiB, LRU; images on screen tracked apart | cleared | the toolkit | through a custom provider's key |
| GTK 4 | nothing | | | | | the app (Amberol keeps a `HashMap` of `gdk::Texture` keyed by a SHA-256 id, plus a file on disk); libsoup's `SoupCache` (50 MB) if the app adds it | yes, its own |
| WinUI 3 | decoded, internally | memory | the resolved URI and the decode size | none exposed: no size, no expiry, no clear | the toolkit's | the toolkit, the HTTP stack for remote bytes | NO: a stream "has no shared URI identity" and is decoded every time. The Community Toolkit's ImageCache keeps encoded files, by URI only |
| React Native | iOS: decoded (`RCTImageCache`) plus URLCache; Android: Fresco's decoded and encoded | memory and disk | iOS: URL, width, height, scale and resize mode | iOS 2 MB an image, 20 MB in all; Fresco a quarter of the heap and 40 MB of disk | iOS cleared on a warning and on resigning active | the framework | Fresco through a custom key factory (unverified) |
| Browsers | decoded and encoded | memory and the HTTP disk cache | URL | Firefox discards decoded data for images scrolled far away and decodes again on draw | discarded | the browser | n/a |

What the survey says, for a toolkit that does not fetch:

1. Every cache of DECODED images is keyed by the SOURCE'S IDENTITY and,
   almost everywhere, the DECODE SIZE: Glide's, Nuke's, SDWebImage's, React
   Native's and Flutter's `ResizeImage` keys carry it, so two sizes of one
   picture are two entries. Coil is the exception: it puts the size in the
   key only for transformed requests and serves a smaller request from a
   larger entry.
2. The DISK caches hold ENCODED bytes, and they belong to whoever did the
   fetch: the HTTP layer (URLCache) or the image library (Coil's DiskCache,
   Glide's DiskLruCache, SDWebImage's and Kingfisher's disk stores). A
   toolkit that does not fetch is in neither position.
3. The decoded caches are bounded by MEMORY, not by count alone, and they
   give memory back when the system asks (iOS memory warnings, Android's
   `onTrimMemory`).
4. BYTES THE APP HANDS OVER GET NO IDENTITY unless the app names them.
   Glide caches `load(byte[])` nowhere by default, Coil does not memory-cache
   a `ByteArray` without a `memoryCacheKey`, Flutter's `MemoryImage` misses
   on equal bytes in a new buffer, and WinUI decodes every stream afresh. The
   libraries that do cache app bytes (Kingfisher, SDWebImage, Nuke) take an
   app-given key. kaya is always in this position, since it never sees a URL.
5. The one platform cache already in kaya's path is WinUI's, and it is keyed
   by URI, so it never helps kaya's streams.
6. The bounds are fractions of memory or screens, never a fixed count alone:
   a quarter of RAM (Kingfisher), 15% (Nuke), 20% of the heap (Coil), two
   screens (Glide), 100 MiB (Flutter), 20 MB (React Native on iOS).

### What kaya does today

- **The image kind.** `image` takes `source` (prop 6), a Blob: the guest's
  bytes, an asset, a bound signal of bytes, or a row's bytes field. It draws
  at the picture's natural size, or scaled down inside `max_width` and
  `max_height` (props 42, 43, docs/photo-attach-plan.md §2). `bleed` (61)
  fills to the window's edge (docs/safe-area-plan.md A3).
- **Undecodable bytes draw nothing, silently.** Every backend keeps the
  widget and draws it 0x0 (tools/check-empty-child.py holds the "one node is
  one widget" half); tools/scenes/gallery.steps reads `expect image#1 "0x0"`.
  Nothing tells the app. WINUI DIVERGES: its arm only logs the error and KEEPS
  THE PREVIOUS PICTURE (crates/kaya/src/winui/mod.rs, the source arm), so a
  bad second picture leaves the first one showing there and nowhere else. N14
  fixes it.
- **Every backend decodes on the UI thread, during apply, with no cache.**
  SwiftUI builds `NSImage(data:)` or `UIImage(data:)` in the apply arm, which
  defers the real decode to the first draw, also on the main thread. Compose
  calls `BitmapFactory.decodeByteArray`, GTK `gdk::Texture::from_bytes`, both
  eagerly on the UI thread. WinUI writes the bytes into an in-memory stream
  (blocking on `StoreAsync`) and calls the synchronous `SetSource`, which
  Microsoft documents as the path that loses background, right-sized
  decoding.
- **A stamped image decodes on every stamp.** A blob handle lives for one
  batch (docs/traps.md, "A BLOB HANDLE DIES WITH ITS BATCH"), each stamp
  ships its own `SetProp(Source)`, and the Swift and Kotlin pumps copy the
  bytes per handle. A row scrolled out of the band tears its widgets down and
  decodes again when it comes back.
- **A row update re-sends an unchanged picture.** `update_entry`
  (crates/kaya/src/scene.rs) re-pushes every bound prop of a same-variant row
  without comparing, so changing a row's "now playing" flag decodes its album
  art again.
- **A write to a removed row panics.** `kaya: update of missing key …`
  (scene.rs, `update_entry`). A download that finishes after its row was
  deleted would, written back naively, kill the guest.
- **The core already decodes PNG and JPEG**, for the canvas: `load_image`
  (record 74) decodes an asset or a picked file with the `png` and
  `zune-jpeg` crates, synchronously on the submitting thread, into a
  core-held premultiplied RGBA8 image, and REFUSES an http(s) URL by name:
  "kaya fetches none" (crates/kaya/src/reader.rs, `load_image`). That refusal
  is the precedent N1 records.
- **The one place a platform fetches for kaya** is media: a player's `source`
  and its caption sidecar may be http(s) URLs, fetched by AVPlayer, media3,
  GStreamer and MediaPlayer with their own networking, "never an HTTP client
  in the core" (docs/media-plan.md §7a and the 2026-09-30 sidecar ruling). The
  player's `artwork` is an asset name only.
- **Background work** is `post`, in all nine bindings: a closure queued from
  any thread that runs as its own transaction on the app thread
  (docs/background-work-plan.md). Four bindings also resume an `await` on the
  app thread with no transaction open, and write through an explicit scope
  (DESIGN.md, "Async dialogs use explicit transaction scopes"): Swift's actor
  executor, C#'s `AppThreadContext` synchronization context, Rust's scoped
  tasks, and JS, whose app thread is the worker its event loop runs on. Java's
  `HttpClient.sendAsync` continues on the client's own executor and must
  `post`; Python, Go, OCaml and Haskell use a thread and `post` (the ruled
  callback carve-out).
- **Bytes in a row.** Eight bindings have a bytes field in a row's record
  (Python `bytes`, Go `[]byte`, C# and Java `Field<byte[]>`, Swift
  `KayaField<Data>`, OCaml `bytes`, Haskell `KField ByteString`, JS
  `Uint8Array`). RUST HAS NONE: its `KayaField` covers String, Document,
  bool, i64, f64, Date, Time, Color and PlayerId (crates/kaya/src/app.rs).
- **No HTTP anywhere.** No guest or binding fetches over HTTP today, and
  Cargo.lock has no HTTP or TLS crate. Python, Go, C#, Java, Swift and JS have
  a client in their standard library; Rust, OCaml and Haskell do not, and
  the flake gives OCaml and Haskell none.
- **No word for loading.** Nothing in the spec or any binding lets an image
  say "loading". `placeholder` (prop 30) is an entry's prompt text.
- **No image glyph** in the symbol vocabulary (`wire::SYMBOLS`: add, remove,
  delete, edit, done, close, search, settings, refresh, info, warning, back,
  forward, more, copy, paste, star, lock, person, home, emoji, send, attach,
  mic).
- **The core owns stamping.** The backend reports the scroll geometry and the
  core stamps and tears down copies, so the core knows which rows are
  realized; the guest writes no windowing code (docs/virtualization-plan.md
  §1). The media feed already turns realization into something a guest can
  act on: video views report visibility and the core holds a row player's
  source until its view is first visible (docs/media-plan.md §7d).
- **The lane media server** (tools/media-server.py, started by
  tools/lib/media_server.py when a `media_` leg is queued, and by the linux
  runner's own copy) serves the flat files of guests/assets/media with Range,
  and a `/trickle/` prefix that sends one byte every 2 s, so a request never
  finishes in a leg's time. It has no 5xx route, serves no images, and no gate
  names it. Guests learn its address from `KAYA_MEDIA_URL`.

### Decode cost and memory, MEASURED

The mac host is an M5 Pro on macOS 26.6.2; the GTK numbers are the lane image
(GTK 4.24.0) in docker on the same host; the core's are the crates kaya pins.
Medians of 15. The pictures are generated noise, 600x600 at 138 KB as JPEG,
which is the size and weight of a music service's album art.

| picture | macOS ImageIO full decode | macOS, downsampled to 240 px | GTK `Texture.new_from_bytes` | core (`zune-jpeg` 0.5.15, `png` 0.18.1) |
|---|---|---|---|---|
| 600x600 JPEG, 138 KB | 1.16 ms | 1.47 ms | 0.93 ms | 1.18 ms |
| 600x600 PNG, 78 KB | 0.95 ms | 1.32 ms | 1.04 ms | 0.53 ms |
| 1200x1200 JPEG | 2.65 ms | 1.75 ms | 1.50 ms | 1.98 ms |
| 3000x3000 JPEG, 1.16 MB | 15.2 ms | 7.8 ms | 11.0 ms | 14.8 ms |
| 3000x3000 PNG | 10.8 ms | 19.0 ms | 13.9 ms | 4.8 ms |

`NSImage(data:)` itself took 0.06 to 0.12 ms for every picture, because it
decodes nothing until drawn. GTK's `GdkPixbufLoader` with `set_size(240, 240)`
was SLOWER than the full texture decode (2.7 ms against 0.9 ms for the 600
JPEG): downsampling is not free on every platform.

What that means for a scrolling list. A fast fling on a phone brings several
new rows into the band per frame. At one millisecond a tile on the fastest
desktop chip Apple sells, ten new rows are 10 ms of UI-thread work, more than
a 120 Hz frame before anything else is drawn; a phone's cores are slower, and
the arithmetic only gets worse (the phone numbers are the depth's to measure,
§7). One 3000x3000 photo is a whole 60 Hz frame on its own.

Memory of 100 decoded 600x600 tiles, each from different bytes:

| | kept at full size | downsampled to 144 px (48 pt at 3x) |
|---|---|---|
| arithmetic, 4 bytes a pixel | 144 MB | 8.3 MB |
| GTK, RSS growth | +106.5 MB (1.07 MB each: GTK keeps a JPEG as 3-byte RGB) | +25.2 MB through GdkPixbufLoader, which carries its own overhead |
| macOS, resident growth | +68.3 MB (the memory compressor folds part of it; `phys_footprint` moved 19 MB either way and is no use here) | +25.3 MB |

The 100 encoded copies were 13.8 MB.

Sources: Apple, AsyncImage (developer.apple.com/documentation/swiftui/asyncimage),
UIImage.prepareForDisplay
(developer.apple.com/documentation/uikit/uiimage/preparefordisplay(completionhandler:)),
redacted(reason:) (developer.apple.com/documentation/swiftui/view/redacted(reason:)),
Asynchronously Loading Images into Table and Collection Views
(developer.apple.com/documentation/uikit/asynchronously-loading-images-into-table-and-collection-views),
WWDC18 session 219, Image and Graphics Best Practices; Apple Developer Forums
thread 682498; Coil, Compose (coil-kt.github.io/coil/compose/) and Getting
started (coil-kt.github.io/coil/getting_started/); Glide, Compose integration
(bumptech.github.io/glide/int/compose.html); Android Developers, Load images
from the internet (developer.android.com/develop/ui/compose/graphics/images/loading)
and ImageDecoder (developer.android.com/reference/android/graphics/ImageDecoder);
Accompanist placeholder migration
(github.com/eygraber/compose-placeholder/wiki/Accompanist-Migration-Guide);
Flutter, Image.network (api.flutter.dev/flutter/widgets/Image/Image.network.html),
ImageCache (api.flutter.dev/flutter/painting/ImageCache-class.html) and
FadeInImage (api.flutter.dev/flutter/widgets/FadeInImage-class.html); GTK,
gdk_texture_new_from_bytes (docs.gtk.org/gdk4/ctor.Texture.new_from_bytes.html);
Sophie Herold, Making GNOME's GdkPixbuf image loading safer
(blogs.gnome.org/sophieh/2025/06/13/making-gnomes-gdkpixbuf-image-loading-safer/);
libglycin (gnome.pages.gitlab.gnome.org/glycin/libglycin/); libadwaita,
AdwSpinner (gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Spinner.html);
GNOME HIG, Spinners (developer.gnome.org/hig/patterns/feedback/spinners.html);
Microsoft Learn, BitmapImage
(learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.media.imaging.bitmapimage)
and Optimize animations, media, and images
(learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media);
Windows Community Toolkit, ImageEx
(learn.microsoft.com/en-us/windows/communitytoolkit/controls/imageex);
React Native, Image (reactnative.dev/docs/image); Expo, Image
(docs.expo.dev/versions/latest/sdk/image/); MDN, aria-busy
(developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-busy);
BlurHash (github.com/woltapp/blurhash); ThumbHash (evanw.github.io/thumbhash/).
Cache sources: Apple, AsyncImage's documentation (the iOS 27 caching
paragraph), URLCache, NSCache and NSCache.totalCostLimit, UIImage init(named:);
blog.eidinger.info/you-better-increase-urlcache-size and
tech.justeattakeaway.com/2021/02/01/urlcache-default-size-is-not-enough/ (the
iOS URLCache defaults); the libraries' own source on their main branches,
read 2026-10-13: Kingfisher (Sources/Cache/MemoryStorage.swift,
DiskStorage.swift, ImageCache.swift), SDWebImage (SDImageCacheConfig.m,
SDMemoryCache.m, SDImageCache.h), Nuke (Sources/Nuke/Caching/ImageCache.swift,
DataCache.swift, Internal/ImageRequestKeys.swift, Loading/DataLoader.swift),
Coil (coil-core's MemoryCache.kt, DiskCache.kt, MemoryCacheService.kt,
RealImageLoader.kt, SystemCallbacks.kt), Glide (MemorySizeCalculator.java,
DiskCache.java, RequestBuilder.java, and bumptech.github.io/glide/doc/caching.html),
Flutter (packages/flutter/lib/src/painting/image_cache.dart,
image_provider.dart, binding.dart), flutter_cache_manager's _config_io.dart;
GTK, GdkTexture (docs.gtk.org/gdk4/class.Texture.html); libsoup's
soup-cache.c; Amberol's src/audio/cover_cache.rs; Microsoft Learn,
BitmapCreateOptions; the Windows Community Toolkit's CacheBase.cs and
InMemoryStorage.cs; React Native's RCTImageCache.mm and
reactnative.dev/docs/images; Fresco, frescolib.org/docs/caching,
DefaultBitmapMemoryCacheParamsSupplier.java and DiskCacheConfig.java; Mozilla
bugs 1149893 and 661304 (decoded-image discarding, read through a search
summary, not the bug pages).

## §1: How kaya's model meets the problem

Two facts about kaya decide most of the design before any ruling.

**kaya writes to rows, never to views, so the recycled-cell bug mostly cannot
happen.** In UIKit a download's completion holds a cell; the cell may now
show another row. In kaya a completion holds a ROW KEY and writes the row's
bytes field through a transaction. Whichever stamped copy shows that row, now
or after it scrolls back, reads the row's current data (docs/virtualization-plan.md
§1). A result can only land on the row it was for. That is Apple's own
recommended fix, built into the data model.

Two stale cases remain, and both are about the ROW, not a view:

1. **The row is gone.** The user deleted the track while its art was
   downloading. The write names a key that no longer exists, and today that
   panics.
2. **The row now wants different bytes.** The row's art URL changed while the
   old download was still running (the app edited the row, or the user
   retried). The older download can finish after the newer one and write
   the older picture over it.

**The fetch is the guest's, and so is its background route.** kaya's part is
that a slow or failed fetch has a look, that the result has a safe way back
to its row, and that the bytes, once handed over, are drawn without stalling
the UI thread or holding a phone's memory hostage.

## §2: The rulings (RULED 2026-10-13, as recommended)

### N1: kaya fetches nothing; the guest hands over bytes (RULED 2026-10-13)

RECOMMEND that the image keeps taking BYTES (and assets), never a URL, and
that no binding's core surface fetches. The guest downloads with its own
language's client on its own background route (N6) and writes the bytes into
the image's `source`, as it does today for a picked photo.

Why: the maintainer's ruling of 2026-10-13. Also, a URL source would carry
everything an HTTP client owns into kaya: authentication headers, cookies,
proxies, certificate trust, redirects, retry policy, caching headers and the
TLS stack, five times over with five answers, under invariant 1. The guest's
own client already has all of it and the guest already knows how its service
wants to be called. `load_image` refusing an http(s) URL by name is the same
rule one record over.

Refused: a `url` prop lowered to each platform's own loader (`UriSource`,
`AsyncImage`, Coil through a dependency): five HTTP stacks, five caches,
five failure vocabularies, and no way for the guest to add a header. Refused:
an HTTP client in the core. The media player stays the stated exception: a
stream is fetched by the platform's player because playback is a transport
(Range requests, adaptive bitrate, DRM) only the player can drive, which
docs/media-plan.md §7a already argues; an image is one finite response.

### N2: Three phases on the image itself, as one enum prop `phase` (RULED 2026-10-13)

RECOMMEND a new image prop, `phase`, an enum of `shown` (the default),
`loading` and `failed`, legal on the image alone, settable, bindable to a
signal and to a row field, in both construction zones.

- `shown`: today's image. The source draws if it decodes; with no source, the
  image is empty, as today.
- `loading`: the image is waiting for bytes. With no source it draws the
  loading look (N4); WITH a source it keeps drawing that source, so an app
  refreshing a picture, or showing a small preview while the large one
  downloads, keeps something on screen. Either way it is busy to assistive
  technology (N5).
- `failed`: the image draws the failed look (N4) whatever its source.

Bytes that do not decode, on an image whose phase is `shown`, also draw the
failed look (N13), so the user sees one failed look whatever failed.

Why: every toolkit surveyed has exactly these three states (§0), and in kaya
the app is the one that knows the first two: only the app knows a download
is in flight, and only the app knows it got a 404. A prop the app writes is
the honest place for what the app knows. An enum, rather than two Bools,
cannot say "loading and failed". Binding it to a row field is what gives a
table one phase per row, and it lets the result write the bytes and
`phase: shown` in one transaction, so no frame shows a decoded picture under
a loading badge or the reverse.

Refused: a sum-typed `source` (`Loading | Failed(reason) | Bytes`). It reads
well and it is the variants design's shape, but the wire's Value has no sum
tag, a sum field in a row is a larger change than one enum field, and the
"loading WITH bytes" case (a refresh) has no spelling in it. Refused:
`on_load` and `on_error` callbacks. kaya does not load, so there is nothing
to call back about, except a decode failure, which N13 handles. Refused for
now: byte progress. Only Flutter and React Native report it, Flutter's total
is often unknown, and a progress ring inside a 48 pt tile is no platform's
idiom; an app that wants a progress bar for a large download puts a
`progress` beside the image and writes its value from the same route.

### N3: A loading or failed image has a box before it has a picture (RULED 2026-10-13)

RECOMMEND that an image may declare its BOX with `max_width` and `max_height`
together and `fit` (prop 51, the video view's enum, `contain`, `cover` or
`fill`). An image with `fit` set takes exactly that box in every phase, and
places the picture in it as the video view does: `contain` letterboxes,
`cover` fills and crops, `fill` stretches. An image without `fit` keeps
today's rule (natural size, or scaled down to fit the bound with its shape
kept).

The root refuses, when the transaction ends, an image whose phase is
`loading` or `failed` (or bound to a field or signal that may be) and which
declares no box: it would draw nothing at no size, so the user would see no
loading state at all. The sentence names `fit` and the two bounds.

Why: without a box the row's layout moves when the picture arrives, and
every row in the band jumps as art lands (React Native requires a network
image's width and height for this reason). Album art is square and drawn as
a square whatever the file is, which is `cover`. Reusing the video view's
`fit` keeps one vocabulary for "a picture in a box" (docs/media-plan.md §3).
`max_width` and `max_height` already mean "the image's room in points" since
docs/photo-attach-plan.md R2.

Refused: a separate `width` and `height` for images: the bound props already
say it, and two ways to size one picture is one too many. Refused: a box
taken from the picture's own header before decoding (the core could read a
JPEG's size in microseconds): it fixes the jump only after the bytes arrive,
which is too late for the loading look.

Image shapes (a round avatar, rounded art) are the styling pass's (the
roadmap's "A styling pass toward an app-skinned look"), and the loading and
failed looks take whatever shape that pass gives the image.

### N4: The looks are a still fill in the platform's own placeholder colour; failed adds the platform's missing-image glyph (RULED 2026-10-13)

RECOMMEND:

- **Loading:** the box filled with the platform's own colour for a
  placeholder or a quiet fill, no glyph, no spinner, no motion.
- **Failed:** the same fill with the platform's missing-image glyph centred,
  at the platform's secondary foreground, drawn only when the box is at least
  twice the glyph's size; a smaller box is the fill alone.

| platform | fill (to confirm in the depth's captures) | failed glyph |
|---|---|---|
| macOS, iOS | the quaternary system fill (`Color(.quaternarySystemFill)` on iOS, the `.quaternary` shape style on the mac), which is what AsyncImage's default grey placeholder resembles | an SF Symbol available at kaya's floors (SF Symbols 4), to choose in the depth: `photo` with a slash is newer than the floor, so the candidate is `exclamationmark.triangle` or `photo` dimmed |
| Android | Material 3's `surfaceVariant` (or `surfaceContainerHighest`) | Material Symbols `broken_image` |
| GTK | libadwaita's card colour or the foreground at the HIG's dim alpha, read from the style, never a literal | the freedesktop icon `image-missing`, which every icon theme carries by name |
| WinUI | `ControlFillColorSecondaryBrush` or `CardBackgroundFillColorSecondaryBrush` | a Segoe Fluent Icons glyph for a broken or missing picture, to choose in the depth |

The glyph joins the symbol vocabulary as `image_missing`, so check-symbols and
check-symbol-parity hold it like the other twenty-four.

Why: the platforms' own lists show a still grey square where art has not
arrived (Music, Spotify, Files thumbnails); none spins one indicator per row.
GNOME's HIG says a spinner is for waits over about three seconds, one at a
time, never flashed, and a row of art finishing in a few hundred milliseconds
would flash a column of them. Shimmer is no platform's native control: Material
3 has no skeleton component and Accompanist's placeholder was deprecated in
2023, WinUI's Shimmer lives in the Community Toolkit's Labs, and libadwaita
has none; it is also motion, which the platforms' reduced-motion settings
would then have to stop. A token rather than a colour keeps this inside the
styling ceiling (DESIGN.md, Brand identity and the styling ceiling): the app
picks no colour.

Refused: a spinner (above). Refused: shimmer (above). Refused: a cross-fade
when the picture lands. SwiftUI's `AsyncImage` and the platform images do not
animate a source change unless asked; Flutter's FadeInImage and Coil's
crossfade are opt-in library features. Deferred: a BlurHash or ThumbHash
placeholder. It needs a server that sends one, and N2 already lets an app
show a preview: a guest that has a hash or a thumbnail decodes it to bytes
and sets them as the source while `phase` is `loading`. KEY for the ledger:
blurhash, thumbhash, image placeholder.

### N5: Accessibility: the label in every phase; busy where the platform has it; a label-less image stays silent (RULED 2026-10-13)

RECOMMEND:

- An image with no `a11y_label` is decorative in every phase, as today, so a
  table of tracks does not chatter "loading" once per row. The row's text is
  what a screen reader reads.
- An image with a label keeps it in every phase. While `loading`, the arm
  sets the platform's own BUSY state where one exists: `GTK_ACCESSIBLE_STATE_BUSY`
  on GTK, `AXElementBusy` on the mac, UIA's `AriaProperties` `busy=true` on
  WinUI (to measure whether Narrator reads it). iOS and Android have no busy
  state on an element; there the arm sets nothing in the depth.
- While `failed`, nothing is added by kaya; an app that wants "Cover art
  unavailable" spoken writes that label.

Why: no platform publishes guidance on what to say for a loading or failed
picture (§0's survey found none; ARIA's `aria-busy` is the only standard
word, and it means "wait, this is changing"). A word kaya chose itself would
be the first string the toolkit ships in its own voice and would need nine
locales' worth of translations; the platforms' busy states are spoken in the
user's language by the screen reader itself.

QUESTION for the maintainer: on iOS and Android, should a labelled loading
image say something? The options are (a) nothing, as recommended; (b) the
app's `a11y_hint` while loading, which the app sets per phase; (c) a word
kaya ships, which this pass recommends against for the reason above.

### N6: The result comes back through the background route the binding already has; nothing new crosses the C ABI (RULED 2026-10-13)

RECOMMEND no new primitive. The fetch runs where each language runs slow work
today, and the result is one transaction that writes the bytes and `phase:
shown`, or `phase: failed`:

| binding | where the fetch runs | how the result is written |
|---|---|---|
| Rust | a scoped task (`tasks.spawn`) awaiting a future the app's HTTP crate completes on its own thread, or a `std::thread` | `app.apply(|tx| …)` after the await, or `ctx.poster().post(|tx| …)` from the thread |
| Swift | `app.task { … }`, awaiting `URLSession.data(from:)` | `app.build { tx in … }` after the await: the actor executor resumes on the app thread |
| C# | an `async` handler awaiting `HttpClient.GetByteArrayAsync` | `app.Build(tx => …)` after the await: `AppThreadContext` resumes on the app thread (never `ConfigureAwait(false)`) |
| JS | `await fetch(url)` | a plain write after the await: the app thread is the worker whose event loop resumed it, and the first write opens the implicit transaction (docs/js-plan.md §4) |
| Java | `HttpClient.sendAsync` | `app.post(tx -> …)` from its `thenAccept`, which runs on the client's executor, not the app thread |
| Python | a `threading.Thread` with `urllib.request` | `app.post(fn)` |
| Go | a goroutine with `net/http` | `app.Post(func(tx *kaya.Tx) { … })` |
| OCaml | `Thread.create` | `post app (fun () -> …)` |
| Haskell | `forkIO` | `post app (…)` |
| C floor | the guest's own thread | its own locked queue and `kaya_wake()` (guests/c/background.c is the shape) |

Live images write a bound signal, or the setter in the bindings that have
one (Go's, C#'s and Java's `SetSource`); stamped images patch their row BY
KEY. Every binding has both routes today except Rust, which needs a bytes
row field first (N16).

Why: docs/background-work-plan.md built `post` so that "any app that wants
to make an HTTP call" would not need anything else, and the async-dialogs
pass gave four languages their own `await`. A network image is the first
real user of both, and it should prove them, not route around them.
`tools/check-tx-liveness.py` already refuses a write from the wrong thread in
every binding, which is the class a fetch callback falls into first.

Refused: an image-specific callback channel in the core (a "deliver bytes to
widget N" record carried outside a transaction): it would be a second
transaction mechanism with weaker semantics than `post`.

### N7: A keyed write that does nothing when its row is gone or has moved on (RULED 2026-10-13)

RECOMMEND a CONDITIONAL row write, available to every binding: patch row K
only if it still exists and its field F still equals V; otherwise the write
does nothing and the transaction goes on. Spelled per binding as its own patch
spelled with a guard (`patch_if(key, guard, changes)` in Rust, a keyword in
Python, a method on the record handle in the curly bindings), one TX record
on the wire, the guard checked by the core inside the transaction.

The image's use: each row carries the URL it wants (`art_url`, a string
field). The completion writes `art` and `phase` with the guard `art_url ==
the URL this download fetched`. A deleted row and a row that has since asked
for a different picture both drop the write, with no panic and no race.

Why: §1's two stale cases are normal events, not bugs, and today the first
one is a crash. A check the guest must remember to make before writing is
the guard nobody walks into (invariant 3); a compare-and-set in the core is
checked against the model the transaction actually commits to, so there is
no window between the check and the write. The guard is general: a
background result of any kind, a price, a status, a transcript, has the same
two stale cases, which is why it is a row write and not an image feature.

Refused: making `patch` of a missing key silent. A handler that writes a row
it believes exists has a real bug, and the panic is how that is found.
Refused: a binding-side check against a mirror of the collection. Not every
binding keeps one, and a mirror can disagree with the core inside the same
transaction.

QUESTION for the maintainer: this is the one ruling that adds a general
transaction record rather than an image prop. The alternative is to leave
the check to N12's helper, in each binding's own code.

### N8: kaya tells the guest when a row's loading image is needed and when it no longer is (RULED 2026-10-13)

RECOMMEND two row handlers on a template image, `on_needed` and
`on_released`, each receiving its row (DESIGN.md, "A stamped handler receives
its row"):

- `on_needed` fires when a stamped copy of the image is realized while its
  phase is `loading` and it has no source, at most once per row until
  `on_released` fires for that row.
- `on_released` fires when the last realized copy of a row's image is torn
  down while its phase is still `loading`.

The core publishes both itself, since it stamps and tears down the copies;
no backend writes a line for them. The realized band includes a viewport of
overscan on each side, so `on_needed` arrives about one screen before the
row is seen, which is a prefetch for free.

Why: every toolkit surveyed fetches when the row is about to be shown and
not before (Apple's sample: "wait until the data source requests a cell to
fetch"; Coil and Glide start when the composable or view needs the image;
SwiftUI cancels when a lazy row leaves). Without a signal, a guest showing a
catalogue must download every row's art up front: 50 tracks is fine, 5,000
search results is 700 MB of JPEGs in memory and five thousand requests. With
`on_released`, a guest can cancel a download the user scrolled past
(`Task.cancel` in Swift, a `CancellationToken` in C#, an `AbortController` in
JS, a `context` in Go; Python and the carve-out languages simply ignore the
result, which N7 makes safe). The media feed's visibility reports
(docs/media-plan.md §7d) are the precedent for a guest acting on what is
realized.

Refused: a general "row became visible" occurrence for every template.
docs/virtualization-plan.md ruled that windowing has no API surface and the
guest makes no promises; this keeps that for everything except the one kind
whose content is fetched on demand, and keys it on the phase, so an app that
never writes `loading` never sees either handler. Refused: kaya cancelling
anything itself; it cannot reach the guest's HTTP client.

QUESTION for the maintainer: this is the largest of the rulings and the one
that touches the windowing ruling of 2026-08-24. Without it, the media player
demo works (its lists are short) and a guest with a long list fetches
eagerly.

### N9: Backends decode off the UI thread, at the size they draw (RULED 2026-10-13)

RECOMMEND that every backend decodes a source on a background thread and
installs the picture on the UI thread when it is ready, and decodes no larger
than the box times the window's scale where the platform offers a
downsampling decode:

| backend | decode | size |
|---|---|---|
| SwiftUI | ImageIO, `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceShouldCacheImmediately`, on a serial background queue (WWDC18 219's recipe), then `Image(decorative:scale:)` from the CGImage | `kCGImageSourceThumbnailMaxPixelSize` = the box's longer side times the scale |
| Compose | `ImageDecoder.decodeBitmap` with `setTargetSize` on API 28 and later, `BitmapFactory` with `inSampleSize` on 26 and 27 (kaya's minSdk is 26), on a background dispatcher | the box times the density |
| GTK | `gdk::Texture::from_bytes` in `gio::spawn_blocking` (documented thread-safe; MEASURED running on a worker) | full size; `GtkPicture` scales on the GPU, and the measured scaled loader was slower than the full decode (§0) |
| WinUI | `BitmapImage.SetSourceAsync` with `DecodePixelWidth` and `DecodePixelHeight`, replacing the synchronous `SetSource` and the blocking `StoreAsync().join()` | the box in physical pixels |

While a source decodes, the image keeps what it showed before: a newly
stamped image shows its loading or empty look, an image whose source was
replaced keeps the old picture. A decode that finishes after its image was
given another source, or was torn down, is dropped: each arm keeps a
generation on the widget and compares it when the decode returns (the guard,
§5).

`expect image "WxH"` keeps reading the picture's NATURAL size, which every
platform's decoder reports from the header (ImageIO's properties, the
`OnHeaderDecodedListener`, `BitmapImage.PixelWidth` after `ImageOpened`),
so a downsampled decode does not change what the scenes read.

Why: §0 measured a 600x600 tile at about a millisecond on the fastest host
there is and a 3000x3000 photo at a whole frame, and every backend does it on
the UI thread today. Every platform documents a background decode path and
says to use it; WinUI's documentation says the synchronous `SetSource` kaya
uses is exactly the path that loses it. The size rule cut the 100-tile table
from 106 MB to 25 MB on GTK's loader and from 68 MB to 25 MB on the mac.

Refused: decoding in the core, the canvas's rule ("kaya rasterizes, backends
blit"). It would put the decode on the app thread (off the UI thread too) and
give one failure rule, but the core decodes PNG and JPEG only, where the
platforms also read WebP, GIF, HEIF and AVIF, and it ignores colour profiles
(reader.rs takes every image as sRGB), so a wide-gamut photo would draw
differently from the same file in Photos. The canvas needs one decoder for
one hash; an image widget needs the platform's own picture.

### N10: The cache: decoded pictures in each backend, keyed by the bytes' content, bounded by memory; no disk cache in kaya (RULED 2026-10-13)

RECOMMEND:

1. **The core gives every blob a CONTENT ID**: a 64-bit hash of its bytes and
   their length, computed once when the bytes are registered, and sent with
   the blob in every apply. Identical bytes have identical ids whichever row
   or signal holds them.
2. **Each backend keeps a decoded-picture cache keyed by (content id, decode
   size)**, least recently used first out, bounded by MEMORY: two screens'
   worth of pixels at the window's scale beyond the pictures on screen (a
   phone of 1179x2556 is 12 MB a screen; a 2560x1600 desktop 16 MB), emptied
   when the system asks for memory (`didReceiveMemoryWarning` on iOS,
   `onTrimMemory` on Android). A cache hit draws in the same frame as the
   stamp, with no loading look and no decode.
3. **The pump skips the copy** of a blob whose content id it already has
   decoded at that size.
4. **The core stops re-sending an unchanged source** on a row update
   (`update_entry` compares a bound Blob before pushing it, by `Arc`
   pointer first and bytes second).
5. **No disk cache in kaya.** The encoded bytes belong to the guest that
   fetched them; keeping them across launches is the HTTP layer's or the
   guest's (N12).

Why: the survey (§0) says every decoded cache is keyed by the source's
identity and, nearly everywhere, the decode size, bounded by a share of
memory or screens and dropped under pressure. It also says that bytes an app
hands over get no identity unless the app names them, and the libraries that
cache app bytes (Kingfisher, SDWebImage, Nuke, Coil's `memoryCacheKey`,
Glide's `signature`) take an app-given key. They can afford to, because
their normal key is a URL they fetched and the app key is the rare case. For
kaya every image is that rare case, and an app-given key can lie: a key
reused for new bytes paints the old picture, which is the bug this pass
exists to prevent. A content id cannot lie, costs the core one hash per
registered blob, and gives album art the dedupe it most needs: twelve tracks
of one album carry the same bytes, which decode once. The bound in screens is
Glide's own sizing (its MemorySizeCalculator counts screens), and ties the
budget to the display rather than to a number someone guessed. Without a
cache, scrolling a row away and back decodes again (§0's millisecond a tile,
on every frame of a fling over rows already seen), and today every update of
any field of a row decodes its art again.

Options weighed, as the maintainer asked:

| | what | costs | verdict |
|---|---|---|---|
| (a) no cache | the guest keeps bytes; backends decode on every stamp | a re-decode per row per pass of the band, and per update of any row field; twelve decodes of one album's art | refused: it fails the scroll-back case every list library exists to fix |
| (b) decoded memory cache, keyed by an APP-GIVEN key | the guest names each picture, as Kingfisher's `store(_:forKey:)` and Coil's `memoryCacheKey` do | a stale or reused key paints the wrong picture; nine bindings grow a key argument | refused: the content id gives the same hits with no way to be wrong |
| (b′) decoded memory cache, keyed by CONTENT | the recommendation | four backend caches, held to one rule by a gate (§5); a hash per registered blob (MEASURE at the depth; a fast 64-bit hash of 140 KB is tens of microseconds) | RECOMMEND |
| (c) an encoded byte cache with disk persistence | kaya stores fetched bytes across launches | kaya does not fetch, so it would be caching what the guest already holds, keyed by a URL it never sees; disk quotas and eviction on five platforms | refused in the core; a helper may keep one (N12) |
| (d) per-binding helpers only | the cache lives in the helper | a helper can hold bytes but not decoded pictures, which are backend objects | refused as the whole answer; the helper owns the byte side (N12) |

QUESTION for the maintainer: the cache is the one part of this pass he said
he was unsure about. The recommendation is (b′) plus (d) for bytes.

### N11: Who owns which bytes (RULED 2026-10-13)

RECOMMEND, stated once so every backend and binding agrees:

- The GUEST owns its downloaded copy and may drop it the moment it has
  written the source; registering copies the bytes (DESIGN.md, the blob
  table).
- The CORE owns the encoded bytes for as long as a row field or a signal
  holds them: a 100-row table of 140 KB art is 14 MB in the core. Identical
  bytes share one allocation (the content id makes that interning free).
  The core never drops app data by itself.
- Each BACKEND owns decoded pictures, only for realized copies and the N10
  cache, and releases a copy's picture when its widget is torn down.

For a long list, the bytes of far-off rows are the guest's to drop, by
writing the row back to `loading` with no source when `on_released` (N8)
fires for a row it no longer expects to show; the helper (N12) does this
past a count it is given.

Why: the core's model is the app's data and must not change under it
(docs/virtualization-plan.md: "the collection is whole"). Decoded pixels are
ten times the encoded size and are the part worth bounding; the encoded
bytes of a few hundred rows are tolerable, and a guest with thousands has
N8 to keep its set small.

### N12: A small fetch helper in every binding, outside the core, that takes the app's fetch function (RULED 2026-10-13)

RECOMMEND one helper per binding, in the binding's own language and file, not
in the core and not on the wire. It wires N8 to N7:

- `on_needed(row)`: start the app's `fetch(url) -> bytes` on the binding's
  background route (N6), at most a few at a time (six, the browsers'
  per-host limit, by default).
- On success: one conditional write (N7) of the bytes and `phase: shown`.
- On failure: one conditional write of `phase: failed`, and the error handed
  to an app callback if it gave one.
- `on_released(row)`: cancel the download where the language can.
- Optionally an LRU of ENCODED bytes keyed by URL in memory, and on disk in
  the app's own cache directory where the binding can reach one.

The helper takes the FETCH FUNCTION from the app. Six bindings ship a
default built on their standard library (Python `urllib.request`, Go
`net/http`, C# `HttpClient`, Java `java.net.http.HttpClient`, Swift
`URLSession`, JS `fetch`); Rust, OCaml and Haskell have no standard client,
so there the app passes one, and the binding gains no dependency.

Why: the plumbing between "this row needs art" and "write it back safely" is
the same in every app, and it is exactly where the stale-row and cancellation
mistakes would be made nine times over by hand. Keeping it in the binding,
over the binding's own public surface, keeps the core free of HTTP and keeps
the helper replaceable: an app with its own client, auth or cache passes its
own fetch, or skips the helper and calls N7 and N8 itself.

Refused: no helper, examples only. Every guest would re-derive the guard,
the concurrency cap and the cancellation, and the sugar census would have
nothing to hold. Refused: the helper in the core, which is N1's refusal.

QUESTION for the maintainer: Rust, OCaml and Haskell guests need a client
for the scenes and the demo. For the lane's plain-http server, a few dozen
lines over the standard library's sockets would do in Rust and OCaml (Unix
sockets), and Haskell's base has no sockets at all (`process` and `curl`
would). For the media player's real catalogue, which is https, they would
need `ureq` (Rust), `cohttp` with TLS (OCaml) and `http-client-tls`
(Haskell), each a new pinned dependency in the flake. Which does he want?

### N13: Bytes that will not decode draw the failed look; the app is not told (RULED 2026-10-13)

RECOMMEND that a source that does not decode draws the failed look (N4) on
an image whose box is declared, and stays 0x0 on one without a box, as
today. The harness reads it as failed (N15). No occurrence is sent.

Why: a JPEG cut off by a dropped connection decodes on no platform, and the
user should see the same failed look a 404 gives. Telling the app would need
a report from every backend's asynchronous decode back through the core, per
stamped copy, repeated on every restamp, for an answer the app can do
nothing with: the bytes are what the server sent. An app that must know
validates the bytes itself before writing them.

Refused for now: an `image_failed` occurrence. KEY for the ledger:
image_failed, undecodable, decode failure report. It is the item to admit if
an app shows a need, and it has a clear shape (the content id makes it one
report per bytes, not per stamp).

### N14: WinUI clears the picture on a failed decode, like the other three (RULED 2026-10-13)

RECOMMEND, as part of N9's rewrite of the WinUI arm: `ImageFailed` installs
the failed look (or nothing, without a box) instead of leaving the previous
picture up.

Why: §0 found WinUI the one backend where a bad second picture leaves the
first one showing, which is invariant 1's divergence; the gallery scene
cannot see it because it sets one bad source on a fresh image.

### N15: The harness reads the phase off the platform, never the model (RULED 2026-10-13)

RECOMMEND one new observation and no new action:

- `expect_image_phase <target> loading|failed|shown`, read from what the arm
  actually drew: the loading or failed view mounted in place of the picture
  (and the glyph's presence for failed), or a decoded picture installed. A
  phase the arm has not drawn yet reads as what it did draw, so an arm that
  forgot `failed` fails the read rather than echoing the prop
  (docs/segmented-plan.md G10, the model-read defect class).
- `expect_ax` on a labelled loading image reads the busy state where the
  platform has one (N5), on the mac, GTK and WinUI.
- `expect image "WxH"` (natural size) and `expect_image_size` (the drawn box)
  keep their meaning; on a `fit` image the drawn box is the box in every
  phase.

### N16: All nine bindings and the C floor, both zones (RULED 2026-10-13)

Per invariant 2, every language does, and none has a reason to defer:

| binding | `phase` | `fit` on an image | conditional write (N7) | `on_needed`, `on_released` (N8) | helper (N12) | before anything else |
|---|---|---|---|---|---|---|
| Rust | do | do | do | do | do, app passes the fetch | a bytes row field (`Vec<u8>` as a `KayaField`): today a Rust row cannot carry art |
| Python | do | do | do | do | do, `urllib.request` default, thread + `post` | |
| Go | do | do | do | do, chained on the template image (the Go handler-family rule) | do, `net/http` default | |
| C# | do | do | do | do | do, `HttpClient` default, `await` | |
| Java | do | do | do | do | do, `HttpClient.sendAsync` + `post` | |
| Swift | do | do | do | do | do, `URLSession` default, `app.task` | iOS: confirm ATS lets URLSession reach the simulator's `127.0.0.1` (IP literals are exempt as far as this pass read; unverified) |
| OCaml | do | do | do | do | do, app passes the fetch; `'a ask` spelling for the completion | |
| Haskell | do | do | do | do | do, app passes the fetch; `Ask` spelling | |
| JS | do | do | do | do | do, `fetch` default | |
| C floor | do, `kaya_tx_set` of the enum | do | do, the TX record with every field explicit | do, the ring's two occurrences | no helper: the floor is explicit by design | |

Android: the three hosts already declare INTERNET and allow cleartext to
10.0.2.2 only (android/kaya/src/main/res/xml/kaya_harness_network.xml), which
is the media server's address there. Windows guests run unpackaged and need
no capability.

### N17: Its first home: the media player demo's album art (RULED 2026-10-13)

RECOMMEND that the media player demo is where this is used first: a table of
tracks with art per row from a public catalogue over https, `fit: cover`,
art shared by every track of an album (N10's dedupe), the Now Playing pane's
large art as a live image whose source is replaced when the track changes
(the "loading with the old picture" case). The demo is the review page's
subject (§6).

## §3: The lowering, per backend

| backend | loading look | failed look | off-main decode (N9) | cache (N10) | busy (N5) |
|---|---|---|---|---|---|
| SwiftUI, macOS | a `Rectangle` filled with `.quaternary` in the box | the same with the chosen SF Symbol, `.secondary` | ImageIO thumbnail on a serial queue, generation-checked on the main queue | `NSCache` with a cost of bytes and a `totalCostLimit` from the window, keyed by (content id, pixel size) | `AXElementBusy` on the image's element (to measure where SwiftUI lets it be set) |
| SwiftUI, iOS | `Color(.quaternarySystemFill)` | as macOS | as macOS | as macOS, emptied on `didReceiveMemoryWarning` | none (N5) |
| GTK | a `GtkPicture` with no paintable inside a box styled from libadwaita's colours | the `image-missing` icon at the symbolic size | `gio::spawn_blocking` returning the texture to the main context, generation-checked | an LRU in the backend, sized in pixels, emptied on GMemoryMonitor's low-memory warning | `GTK_ACCESSIBLE_STATE_BUSY` |
| WinUI | a `Border` with the fill brush in the image's place | the Fluent glyph in a `FontIcon` (U+E91B `Photo`: the catalog has no broken-image glyph) | `SetSourceAsync` with decode pixel sizes; `ImageOpened` and `ImageFailed` install, generation-checked | an LRU of shared `BitmapImage`s (MEASURED: one serves two Images), emptied on Win32's low-memory resource notification | none (MEASURED: WinUI 3 has no busy or ARIA property) |
| Compose | a `Box` with the fill colour | `Icon(Icons.Filled.BrokenImage)` | `ImageDecoder` or `BitmapFactory` in a `LaunchedEffect` keyed on (content id, size) on `Dispatchers.Default`; leaving composition cancels it | an `LruCache<Key, ImageBitmap>` sized in bytes, trimmed on `onTrimMemory` | none (N5); the loading Box carries no image role, as the empty Box does today |

## §4: The wire

- A new image prop, `phase`, an `Enum("image_phase")` with `shown` (0),
  `loading` (1) and `failed` (2); legal on the image alone, in both zones,
  bindable to a signal and to an enum row field.
- `fit` (prop 51) becomes legal on the image.
- The root's refusal at transaction end (N3): a `loading` or `failed` phase,
  or a phase binding, on an image with no `fit` and both bounds.
- The content id (N10): the apply side's blob table carries a u64 per blob;
  the pump's blob fetch returns it beside the bytes. Not a TX change.
- The conditional write (N7): a new TX record, `patch_if`, carrying the
  collection, the key, the guard's field and value, and the changes as
  `patch` carries them. The spec doc says what a failed guard does: nothing.
- `on_needed` and `on_released` (N8): two occurrence records carrying the
  template image's node and the row's key path; the template image declares
  them as a stamped handler does.
- `image_missing` joins the symbol vocabulary (N4).
- The spec hash moves; the nine wire files, kaya.h and both interpreters'
  hand-copied hashes move with it.
- Harness (not on the wire): `expect_image_phase`.

## §5: The scenes, the server and the gates

Two scenes, because the affordances can be proven without a network and the
network can only be proven with one.

**The affordance scene**, `netimage.steps` in tools/scenes: one guest, no
HTTP. Its "download" is a background thread that PARKS until a click
releases it, background.steps' principle: an implementation that does the
work on the app thread, or writes from the wrong thread, deadlocks rather
than disagreeing.

1. A live image in `loading`: `expect_image_phase image#0 loading`,
   `expect_image_size image#0 "96x96"` (the box before the bytes),
   `expect_ax` reads its label and, on the mac, GTK and WinUI, busy.
2. Release the worker; it posts the bytes and `shown`:
   `expect_image_phase image#0 shown`, `expect image#0 "600x600"` (natural
   size, though the arm decoded at the box), `expect_image_size` unchanged.
3. Refresh: the app sets `loading` with the old source kept, then a second
   release posts new bytes: the old picture is read while loading (`expect
   image#0 "600x600"`), the new one after (`"320x320"`).
4. Failure: a release that posts `failed`: `expect_image_phase failed`.
   Undecodable bytes on a boxed image: `failed` too (N13).
5. A table of 60 rows, each `phase: loading`, art in a bytes field: the rows
   in the band are `on_needed` (the app's counter label reads the band's size,
   never 60); release them; each row's art reads `shown` with ITS OWN size
   (rows carry different sizes, so a picture on the wrong row is a wrong
   number); scroll to the end and back, and the first row's art reads
   `shown` with no `on_needed` for it again.
6. Stale rows: delete a row whose worker is parked, release it, and the app
   lives (N7's no-op); change a parked row's `art_url`, release the OLD worker
   after the new one, and the row reads the new size.
7. Release: scroll a row with a parked worker out of the band, and the app's
   label reads its `on_released`.

**The network scene**, `netimage_http.steps`, runs the helper (N12) against
the lane's media server in every language: a good picture, a 404, a 500,
bytes that are not an image, and a `/trickle/` picture that stays `loading`
for the leg's whole length and is released when scrolled away (the server's
log reads "closed by the client" in the languages that cancel). The table
rows share three pictures among twelve rows, the album case.

**The server** grows three things: the images it serves (a new family of
generated album-art JPEGs, say 600x600, 320x320 and 1000x1000, each with a
README and a regeneration command, which moves tools/scenes/assets.steps'
census by design), a `/status/<code>/` prefix that answers that code with no
body, and the `image/jpeg` and `image/png` types. The legs that use it are
`netimage_http` legs, so the lanes start the server for them as for `media_`
legs (tools/lib/media_server.py's condition, and the linux runner's).

**Gates that grow:**

- check-verbs: an `image_routes.py` beside tools/lib/segmented_routes.py:
  each arm's decode is inside its one off-main door, never in the apply arm;
  its completion compares the generation before installing; the cache key
  names the content id and the size; `expect_image_phase` reads the drawn
  view, never `phase`; the WinUI arm installs on `ImageFailed` (N14). Watched
  negatives per clause, counts printed.
- check-sugar-surface: `phase`, `fit` on the image, the conditional write,
  the two handlers and the helper in all nine, both zones, fake-name and
  rename-in-a-copy negatives.
- tpl-surfaces: `phase` and the handlers in the template zone's census.
- check-symbols and check-symbol-parity: `image_missing`.
- check-tx-liveness: the helper's completions write through the binding's
  own scope, never a captured transaction.
- check-stubs: `depth_stub("netimage")` on GTK, WinUI and Compose until the
  breadth.
- check-assets: the new image family and the server's prefixes.
- check-compose-state: the phase and the decoded picture are composition
  state.
- check-empty-child: the loading and failed views keep one node per widget.
- A runtime negative on the mac, check-empty-child's shape: the
  interpreter's decode door cut out and run against a picture whose second
  source arrives before the first finishes decoding; the probe demands the
  second picture, and the cut with the generation check removed is watched
  showing the first.
- unit tests in the core for the content id (identical bytes, one id),
  `update_entry`'s comparison, the conditional write's two drops, and the
  two handlers' once-per-row rule, each watched failing with its line cut.

## §6: Build order

1. The depth's measurements (§7), on the mac and the simulator, before any
   arm: where SwiftUI lets `AXElementBusy` be set, the SF Symbol at the
   floor, the decode cost on the iOS simulator and on the API 35 emulator,
   the hash's cost.
2. The core's prerequisites, each with its tests: the content id, the
   unchanged-source comparison in `update_entry`, the conditional write, and
   Rust's bytes row field.
3. The depth: spec (`phase`, `fit` on images, `patch_if`, the two
   occurrences, the symbol, the N3 refusal), the core and its unit tests, the
   harness verb, the SwiftUI arm on both Apple platforms (iOS compiled, not
   run) with the off-main decode and the cache, the Rust binding and its
   helper, the Rust guest, `netimage.steps` green on the mac. GTK, WinUI and
   Compose depth stubs; the BUILD and DEFERRED ledger entries (N4's BlurHash,
   N13's report) with KEY lines.
4. The server's family and routes, `netimage_http.steps` on the mac with the
   Rust helper.
5. The breadth: GTK, WinUI (with N14) and Compose per §3; the iOS legs; the
   eight other bindings and the C floor.
6. The media player's art (N17).
7. The matrix once, then the review page: every lane's capture of a table
   mid-load (loading looks in the band), loaded, a failed row, and the Now
   Playing art refreshing.

## §7: Measured, and to be measured

- MEASURED 2026-10-13 (mac, M5 Pro, macOS 26.6.2, load average 4.6; a Swift
  probe built with `kaya_swiftc -O`, medians of 15): the decode table in §0.
  `NSImage(data:)` is lazy (0.06 to 0.12 ms whatever the picture); the full
  ImageIO decode of a 600x600 JPEG of 138 KB is 1.16 ms, of a 3000x3000 JPEG
  15.2 ms.
- MEASURED 2026-10-13 (the lane image, GTK 4.24.0, PyGObject 3.58, in docker
  on the same host): `Gdk.Texture.new_from_bytes` 0.93 ms for the 600 JPEG,
  11.0 ms for the 3000 JPEG; it ran on a worker thread for all five pictures.
  GTK printed "Glycin running without sandbox", so in 4.24 the constructor
  goes through glycin. `GdkPixbufLoader` was slower at every size, and slower
  still when asked to downsample.
- MEASURED 2026-10-13 (the crates kaya pins, `png` 0.18.1 and `zune-jpeg`
  0.5.15, the calls reader.rs makes, release build): 1.18 ms for the 600
  JPEG, 14.8 ms for the 3000 JPEG.
- MEASURED 2026-10-13: memory of 100 decoded 600x600 tiles, the table in §0.
- Read from the tree 2026-10-13: every backend decodes on the UI thread in
  its source arm, no backend caches, each stamp decodes, `update_entry`
  re-sends unchanged bound props, a patch of a missing key panics, WinUI keeps
  the previous picture on a failed decode, Rust has no bytes row field, and
  the media server serves no images and has no 5xx route.
- To measure at the depth: the decode cost on the iOS simulator and the API
  35 emulator (both run on the host's cores, so a real phone's number is
  still a guess; the review page can take one from a device if the
  maintainer wants it); the content hash's cost per registered blob; whether
  SwiftUI exposes `AXElementBusy`; what Narrator reads for a busy image;
  whether ATS allows `http://127.0.0.1` on the simulator without a key; which
  decoded object WinUI can share between two `Image` elements without a URI.
- MEASURED 2026-10-13 at the depth (mac, M5 Pro, a release build, medians of 15,
  load average 6.5): the content id, SipHash-1-3 over the bytes and their
  length (std's DefaultHasher, no new dependency), 52.5 µs for 140 KB and
  389 µs for 1.16 MB, once per allocation since the id is memoized per Arc.
- MEASURED 2026-10-13: AppKit's 26.5 headers export no AXElementBusy (only
  the busy indicator role) and SwiftUI has no busy modifier or trait, so the
  SwiftUI arm sets no busy state on the mac either; N5's busy is GTK's and
  WinUI's, at the breadth. `expect_ax` reads `image/<label>` on the loading,
  shown and failed looks alike.
- MEASURED 2026-10-13: SF `photo.badge.exclamationmark` is SF Symbols 2024
  (macOS 15, iOS 18), above kaya's floors; the failed glyph is `photo` (2019)
  at the secondary foreground.
- MEASURED 2026-10-13: the Rust guests' fetch (`ureq`, its own sockets)
  reaches the lane's server at `http://127.0.0.1` from the iOS simulator with
  no ATS key, since ATS governs URLSession; the Swift helper's URLSession
  measures it at the breadth.
- Not measured at the depth: the decode cost on the iOS simulator and the API
  35 emulator. The SwiftUI arm decodes off the main thread on both Apple
  platforms whatever the number, so it decides nothing there; Compose's arm
  measures it at the breadth.
- Taken at the depth, a recommendation where the rulings are silent: a row
  that a windowed site's SEED realizes (128 rows, before the backend has laid
  anything out) is not `needed` until the backend's first report, which then
  needs the band's rows; without it a 300-row table started 128 fetches and
  released most of them at once.
- Found at the depth: a signal of bytes could not be written (docs/traps.md),
  the mac table's scroll to its last rows reported a one-row band
  (docs/traps.md), and the mac native table's rows taller than its 24pt floor
  run past the window (docs/deferred.md's OPEN entry), which is why
  netimage.steps' table art is 20pt.

## §8: What the maintainer is asked

RULED 2026-10-13 (the maintainer: "im okay with those rulings"): N1-N17 as
recommended, including N7's conditional write in the core, N8's two
handlers, N10's content-keyed decoded cache with no disk cache, and N5's
silence beyond the label on iOS and Android. N12, which carried no
recommendation, is taken as the pinned clients (`ureq` for Rust, `cohttp`
with TLS for OCaml, `http-client-tls` for Haskell), since the media
player's catalogue is https and a plain-socket client cannot reach it.

Every ruling above is his. Four need something only he can supply:

1. N7: a general conditional row write in the core (recommended), or the
   stale-row check left to each binding's helper.
2. N8: the two realization handlers on a loading template image
   (recommended), which reach past the 2026-08-24 "windowing has no API
   surface" ruling for this one case; without them a long list fetches all
   its art up front.
3. N10: the cache he was unsure about: (b′), a decoded cache in each backend
   keyed by the bytes' content and bounded by screens of memory, with no disk
   cache in kaya (recommended), against (a), (b), (c) or (d).
4. N12: what Rust, OCaml and Haskell use to fetch: a standard-library socket
   client good for the lane's plain http, or pinned `ureq`, `cohttp` and
   `http-client-tls` for the demo's https catalogue.

And one smaller one, N5: whether a labelled loading image on iOS and Android
says anything at all.

## §7, breadth: measured 2026-10-13

- The failed glyph, `image_missing` (symbol 25): SF `photo` (Apple's catalog
  has no broken-image symbol at kaya's floor: photo.badge.exclamationmark is
  SF 2024, photo.trianglebadge.exclamationmark 2024.3), Material
  `BrokenImage`, GTK `image-missing-symbolic` (draws a dashed picture frame in
  adwaita-icon-theme 51.0), Segoe Fluent U+E91B `Photo` (none of the 1074
  catalog glyphs is a broken or missing picture; U+E8B9 is two stacked
  frames).
- Busy (N5): GTK's GTK_ACCESSIBLE_STATE_BUSY reads true off AT-SPI on a
  labelled loading image and false otherwise. WinUI 3's metadata carries no
  busy and no ARIA identifier (AutomationProperties has ItemStatus and
  LiveSetting, neither a busy state), so WinUI sets none, as the mac. Busy is
  GTK's alone; no shared scene can hold it, so tools/lib/netimage_gtk.py does.
- WinUI, the windows VM (UTM arm64 Windows 11, release kaya.dll, medians of
  15): the UI thread's time in the call, and the call to ImageOpened.

  | picture | sync SetSource, UI / opened | SetSourceAsync, UI / opened | SetSourceAsync at 96 px, UI / opened |
  |---|---|---|---|
  | cover 600 (10 KB) | 2.86 / 4.5 ms | 0.24 / 1.8 ms | 0.26 / 2.0 ms |
  | 600x600 noise JPEG (121 KB) | 3.51 / 4.8 ms | 0.34 / 2.8 ms | 0.37 / 3.1 ms |
  | 3000x3000 noise JPEG (1.19 MB) | 65.6 / 86.7 ms | 1.10 / 19.4 ms | 0.92 / 18.8 ms |

  PixelWidth and PixelHeight report the natural size with a smaller decode
  size set; a detached BitmapImage decodes and raises ImageOpened, but one
  held by nothing but its own SetSourceAsync never does; one BitmapImage can
  be the Source of two Image elements at once; undecodable bytes raise
  ImageFailed and fail the action; Windows.System.MemoryManager fails in
  kaya's unpackaged process ("The object was not found").
- Compose, the API 35 emulator (density 1.0, medians of 15, host load 34-41):

  | picture | box | ImageDecoder full | setTargetSize | BitmapFactory full | inSampleSize |
  |---|---|---|---|---|---|
  | cover-600.jpg | 96 px | 0.33 ms | 0.18 ms | 0.36 ms | 0.11 ms |
  | 600x600 noise JPEG, 138 KB | 96 px | 1.17 ms | 1.08 ms | 1.23 ms | 0.92 ms |
  | 3000x3000 JPEG, 1.16 MB | 96 px | 14.92 ms | 8.97 ms | 14.55 ms | 7.36 ms |
  | 3000x3000 JPEG | 20 px | 14.39 ms | 6.85 ms | 14.19 ms | 6.40 ms |

  The emulator runs on the host's cores; a phone's number is still a guess.
- GTK: §0's lane-image numbers stand (the arm makes exactly that call on a
  worker). The cache counts 4 bytes a pixel against GTK's 3-byte JPEG
  textures, so it evicts early rather than late.
- Each widget backend's table band report reached `window_moved` without
  sending the core's asks (GTK's and WinUI's own band paths; capi's C door
  already sent them), so a guest quiet after setup never fetched; both send
  them now, each held by its route module.
- iOS: URLSession reaches the lane's server at http://127.0.0.1 from the
  simulator with no ATS key, so the Swift guests carry no exception.
- Java: android.jar (API 36) has no java.net.http, and bindings/java compiles
  into the Android hosts, so the Java helper's default fetch is
  HttpURLConnection; a cancel stops the read and frees the slot, and the
  socket closes only if the server honours `Connection: close`
  (docs/traps.md). Go's context cancel closes it at once.
- OCaml's https is cohttp-lwt-unix over lwt_ssl (nixpkgs builds conduit
  without tls-lwt), certificates verified (docs/traps.md).
- WinUI's loading fill, ControlFillColorSecondaryBrush, is 3 grey levels off
  the window ground and 1 off the table card: nearly invisible. A styling
  call for the review page (docs/deferred.md).
