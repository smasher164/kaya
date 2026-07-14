# kaya

A cross-platform GUI library. Kaya wraps the native widget toolkit on each
platform (AppKit, WinUI, GTK, UIKit, Android views) behind a single API, so
applications built with it look and behave like they belong on the platform
they run on. The core is written in Rust and exposes a C ABI, with the
intent that bindings for other languages stay thin.

Kaya is currently in the design stage and there is no usable code yet. The
architecture and the reasoning behind it are written up in
[DESIGN.md](DESIGN.md).
