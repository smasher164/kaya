# kaya

A cross-platform GUI library. Kaya drives the native widget toolkit on each
platform (SwiftUI on macOS and iOS, WinUI 3 on Windows, GTK4 on Linux,
Jetpack Compose on Android) behind a single API, so applications built with
it look and behave like they belong on the platform they run on. The core
is written in Rust and exposes a C ABI, while guest-language bindings stay thin.

Kaya is implemented and validated but not yet released. Eight language
bindings (Rust, Python, Go, C#, Java, Swift, OCaml, Haskell) plus the
explicit C floor run a shared scene suite byte-for-byte identically across
all five platforms. There are no published packages yet.

The architecture and the reasoning behind it are written up in
[DESIGN.md](DESIGN.md). Contributor/agent operating rules are in
[AGENTS.md](AGENTS.md), workflows in [docs/HACKING.md](docs/HACKING.md),
and the open-work in [docs/deferred.md](docs/deferred.md).
