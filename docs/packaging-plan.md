# Packaging, part 1 — a complete app from one manifest

Ruled 2026-09-08 (the maintainer, in conversation, after the S3 review page's
Windows capture found the toast invisible until the app's AUMID was
registered by hand). This document is the record of those rulings and the
mechanics they need; docs/app-identity-plan.md I7 ratified the shape (one
declaration, two readers) and left the desktop packaging rows "later".
This is later.

## §0 — What part 1 is, and is not

PART 1 PRODUCES ARTIFACTS THAT RUN AS COMPLETE APPS on each platform the
lanes test, every one derived from `guests/assets/identity.toml` — the
name, the mark, the reverse-DNS id and the launch slot — with nothing
retyped anywhere. It is not distribution: stores, package managers,
signing for other people's machines, notarization and updates are PART 2,
and none of them change the artifact's shape; they wrap it.

## §1 — The rulings

- **P1. One declaration generates everything.** identity.toml is the only
  place the name, the mark and the id are spelled. Every platform's
  identity artifact — bundle plist, package manifest, desktop entry, icon
  set, splash — is generated from it by a build step. A build step that
  retypes a value is a check-app-identity finding (its C6 clause already
  says so for paths).
- **P2. Every size is downsampled from the ONE icon the manifest names.**
  CORRECTED 2026-09-08 the same morning: the first draft had the packager
  RENDER kaya's four-quadrant mark at each size, which can only ever
  package kaya's own app — a user has an icon file and a line in
  identity.toml, and the packager must work from that. So `icon` names a
  single large source, a PNG 1024 square or bigger, and every platform
  size — Windows tiles at 44/150/310x150 and the 620x300 splash, the iOS
  icon set, Android's densities, the mac icns rungs, the Linux hicolor set
  — is DOWNSAMPLED from it by tools/lib/packaging/mark.py's own box-filter
  resampler (pure python; a source smaller than a requested size is
  refused, never upscaled). The example app's source is a 1024 PNG
  generated ONCE from the quadrant description in
  guests/assets/icons/README.md and committed; the renderer's only job
  from here is regenerating that asset, and check-app-identity holds the
  committed file byte-identical to its output. No packaging arm may call
  the renderer. The running app still sends the declared file's bytes over
  the wire, as today. SVG sources and per-purpose icons (a monochrome
  Android status icon, a maskable adaptive icon) are part 2, when an app
  needs them; identity.toml grows a key per purpose then.
  AND NO SHARED SCENE DEPENDS ON THE ICON'S SIZE: tools/scenes/assets.steps
  had frozen the declared mark's decoded size (`expect image#0 "64x64"`)
  through an image widget showing it, and a 1024px intrinsic image would
  have put the phones back on the measured layout cliff
  (guests/assets/images/README.md). Ruled 2026-09-08: the assets guests show
  the scenery picture in that widget and keep reading the mark's BYTES for
  the count the label carries, so the scene's subject (the asset census)
  is unchanged and a user-sized icon costs no scene anything.
- **P3. Windows is two runtime situations, not two products.** A kaya app
  is a LIBRARY's process, and a process is either running from an
  installed package or it is not — `GetCurrentPackageFullName` says which.
  PACKAGED (an MSIX built from the manifest: `Identity`, `VisualElements`
  with the display name, the launch background and the rendered logo set):
  identity, taskbar grouping, toast attribution and closed-app activation
  come from the package and the library writes nothing. UNPACKAGED (a
  Python script from a terminal, `cargo run`, a copied Go binary, the
  lane's language hosts, which cannot be packaged without shipping their
  runtimes): the library registers its declared identity at launch —
  `SetCurrentProcessExplicitAppUserModelID`, then
  `HKCU\Software\Classes\AppUserModelId\<id>` with `DisplayName` and an
  `IconUri` pointing at the mark written under LocalAppData — idempotently,
  a no-op when the process finds itself packaged. Without that key Windows
  draws no toast for the app (measured 2026-09-08). The lane runs the
  Rust guests BOTH ways, since users will do both.
- **P4. macOS: one bundle generator.** The lane's wrapper (tools/lib/lanes
  /mac.py `stage_rust`) becomes the generator's mac arm: Info.plist from
  the manifest, the icns resampled from the declared icon, ad-hoc signature, LaunchServices
  registration. One code path for the lane and for a shipped bundle.
- **P5. Linux: a desktop entry and the icon theme.** `<id>.desktop`
  (Name, Icon, Exec, DBusActivatable) and the mark in the hicolor icon
  theme at the sizes GNOME reads, generated into a staging directory; a
  per-user install copies them under `~/.local/share` (no root). The
  notify leg's hand-written desktop entry is replaced by the generator's,
  so the lane runs what an installed app has.
- **P6. The phones are already there.** The APK and the iOS bundle read
  the manifest today; they move onto the shared reader and resample the
  declared icon (the iOS icon set, Android's densities) instead of copying
  the 64px file, without changing what they produce otherwise.
- **P7. Guards.** check-app-identity holds every generator to the manifest
  (C6) and the renderer to the asset (P2); the lanes run the artifacts —
  bundled mac legs, packaged Windows legs beside the unpackaged ones, the
  Linux notify leg on the generated desktop entry — so a generator that
  drifted fails a leg, not a review.

## §2 — What exists and what is built

| platform | artifact | reader today | part 1 builds |
|---|---|---|---|
| Android | APK: mipmap, label, splash theme | android/build.gradle.kts, tools/android/run-emulator.py | the shared reader; resampled mipmap densities |
| iOS | .app: icon, CFBundleDisplayName, launch screen | tools/ios/run-sim.py `make_bundle` | the shared reader; the icon set resampled from the source |
| macOS | .app: plist, icns | tools/lib/lanes/mac.py `stage_rust` (lane wrapper) | the generator's mac arm; the wrapper calls it |
| Windows | MSIX: AppxManifest.xml, logo set, splash; unpackaged self-registration | none | both (P3) |
| Linux | `<id>.desktop`, hicolor icons | tools/linux/notify-leg.sh writes a lane-only entry | the generator's linux arm; the leg uses it |

The generator is `tools/package.py <platform> <exe> [--out DIR]`, python on
the kaya_gate prelude, with the arms in tools/lib/packaging/ (`identity.py`
the one manifest reader, `mark.py` the resampler — and, for the example
app only, the four-quadrant renderer that tools/regen-mark.py writes the
source with — one module per platform).

## §3 — Unknowns to measure on the Windows VM before the arm is built

The VM (Win 11 Pro 26200 arm64) has makeappx.exe and signtool.exe under
`C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\{arm64,x64}` and
`Invoke-CommandInDesktopPackage`; Developer Mode is OFF
(`AppModelUnlock\AllowDevelopmentWithoutDevLicense` absent).

1. MEASURED 2026-09-08: the unsigned route does not exist on this build
   (`-AllowUnsigned` refused 0x80080204 with Developer Mode on or off), so the
   package is signed with a self-signed CN=kaya certificate installed once into
   the machine's TrustedPeople store — the one standing provisioning step, part 2
   replaces it; and the install runs only in the console session (schtasks),
   never over ssh (docs/traps.md). The draft's question was:
   INSTALL WITHOUT A STORE: `Add-AppxPackage -AllowUnsigned` needs Developer
   Mode (one HKLM value, admin); a self-signed certificate needs
   `New-SelfSignedCertificate` + signtool + the cert in the machine's
   Trusted People store (also admin, once). Measure both; the lane
   provisions one, stated, and part 2 replaces it with a real certificate.
2. MEASURED 2026-09-08: the caller's environment does NOT cross
   `Invoke-CommandInDesktopPackage` (the `setx` environment does), and without
   `-PreventBreakaway` the launched process has no package identity at all; so
   the packaged leg's launcher is a PAIR, the outer .cmd the lane's door and the
   inner one setting the harness environment inside the package. The draft's
   question was:
   THE LANE'S ENVIRONMENT INTO A PACKAGED PROCESS: `Invoke-CommandInDesktopPackage
   -PackageFamilyName … -AppId … -Command … -Args …` runs an exe with
   package identity and the caller's environment. Measure that
   KAYA_SELFTEST reaches the guest and that the harness's verdict comes
   back through the launcher shape check-steps holds.
3. LIBKAYA AND THE ASSET ROOT INSIDE THE PACKAGE: kaya.dll beside the exe
   (the loader's directory rule) and `assets/` beside it (assets.rs's
   "beside the executable" route) — no launcher, no env.
   MEASURED 2026-09-08: THREE files, not one — kaya.dll, the MRT index as
   resources.pri, and `Microsoft.WindowsAppRuntime.Bootstrap.dll`, which the
   backend loads BY NAME out of the executable's directory; a package without
   it ran with full identity and then panicked at start. `windows.stage`'s
   default `beside` carries all three.
4. MEASURED IN PART 2026-09-08: `MddBootstrapInitialize2` REFUSES to run in a
   process that has package identity (0x80070032, ERROR_NOT_SUPPORTED) — the
   documented packaged shape is a `<PackageDependency>` on the WindowsAppRuntime
   framework in the manifest and no bootstrap call when the process is
   packaged, so the backend skips the bootstrap under `packaged()` and the
   generated manifest carries the dependency with the framework's exact
   Name/MinVersion/Publisher read off the machine. The question below is then
   asked from the packaged side, where the deployment stack resolves the
   framework:
   ANSWERED 2026-09-08: NO. The 2.x framework family has no Singleton and
   packaging deploys none, so the App SDK's notification stack stays gated and
   S9's Windows closed-app click remains a ruling: a
   `windows.toastNotificationActivation` COM activator in the manifest on the
   classic route, or the Main+Singleton packages deployed on every machine.
   The draft's question was:
   THE APP SDK UNDER PACKAGING: whether `AppNotificationManager` posts and
   lists for a packaged exe on this VM (the Singleton question, docs/traps.md).
   If it does, S9's Windows closed-app click has its route and the ruling
   docs/tasks-s3-plan.md owes is answered by packaging; if not, the classic
   route keeps the arm and `CustomActivator` is the next measurement.
5. THE EXE'S OWN ICON: an unpackaged exe's taskbar icon before its window
   sets one is the resource inside the exe. Whether the lane's cross-built
   exes can carry one (a `.rc` through the linker) is measured, not assumed.
   MEASURED 2026-09-08: yes — `llvm-rc -no-preprocess` (nixpkgs) to a `.res`,
   passed through `-Clink-arg`, and the VM read the four quadrant colours back
   off the cross-built exe with `ExtractAssociatedIcon`. Not built in this
   slice; it is docs/app-identity-plan.md's own "Windows before launch" row,
   no longer an unknown.

## §4 — Build order

1. `mark.py` and `identity.py` with their check-app-identity clauses (the
   renderer pixel-identical to the asset; the reader the only TOML parser
   for the manifest in tools/).
2. The mac arm folding the lane wrapper; the Linux arm and the notify leg
   on it; the phones onto the shared reader.
3. The Windows measurements (§3), then the MSIX arm, the packaged lane legs
   for the Rust guests, and the library's unpackaged self-registration.
4. The matrix, and a review page with each platform's launcher, tile or
   desktop entry showing the generated identity.
