{
  description = "kaya - cross-platform GUI library wrapping native widgets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
          # The Android SDK is unfree; accepting the license here is what
          # sdkmanager --licenses does imperatively.
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        }));
    in
    {
      devShells = forAllSystems (pkgs:
        let
          # SDK + emulator + NDK for the Android leg.
          androidSdk = (pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "35" ];
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ "arm64-v8a" ];
            includeNDK = true;
          }).androidsdk;
          # THE SANITIZER COMPILER, under a name of its own so `clang`
          # keeps meaning this shell's 21.1.8 and tools/check-c-bounds.py
          # can ask for this one by name. Every nixpkgs llvm below 22 has
          # an ASan that HANGS before main here (docs/traps.md).
          asanClang = pkgs.runCommand "kaya-asan-clang" { } ''
            mkdir -p "$out/bin"
            ln -s ${pkgs.llvmPackages_22.clang}/bin/clang "$out/bin/kaya-asan-clang"
          '';
          # CPython for the iOS lane (docs/python-mobile-plan.md §D1),
          # pinned HERE rather than by a fetch script: the store's content
          # addressing IS the hash check and the dev-shell fingerprint
          # moves with the pin, so check-pins has nothing to hold.
          # 3.15.0rc1 until the final lands (scheduled 2026-10-01).
          cpythonIos = pkgs.runCommand "cpython-ios-3.15.0rc1"
            {
              src = pkgs.fetchurl {
                url = "https://www.python.org/ftp/python/3.15.0/python-3.15.0rc1-iOS-XCframework.tar.gz";
                hash = "sha256-F4v3vvnNDxiyfKy5ixQzKlukTJQnVD/7cfiAm8HxHDw=";
              };
            } ''
            mkdir -p "$out"
            tar -xzf "$src" -C "$out"
          '';
          # The Android halves of the same pin, one per ABI: both ship in
          # the APK's jniLibs so the artifact runs on an Apple Silicon or
          # an Intel-host emulator (docs/python-mobile-plan.md §D1).
          cpythonAndroid = arch: hash: pkgs.runCommand "cpython-android-3.15.0rc1-${arch}"
            {
              src = pkgs.fetchurl {
                url = "https://www.python.org/ftp/python/3.15.0/python-3.15.0rc1-${arch}-linux-android.tar.gz";
                inherit hash;
              };
            } ''
            mkdir -p "$out"
            tar -xzf "$src" -C "$out"
          '';
          cpythonAndroidAarch64 = cpythonAndroid "aarch64" "sha256-fW+yimk2iEFlb5GaCBQbDjcgg3rGeYc4gDfunSpcVJI=";
          cpythonAndroidX86_64 = cpythonAndroid "x86_64" "sha256-8Ej1xgtTjvxk5MJjmaCiEgLOQwlJ1bLBA2nWJFSKXcM=";
          # Node's type declarations for tools/js-typecheck.py: nixpkgs
          # carries no @types/node, so the two npm tarballs are pinned
          # here like the CPython archives above. Laid out as a
          # node_modules tree so the bare import inside @types/node
          # resolves upward the way node's resolution does.
          nodeTypes = pkgs.runCommand "kaya-node-types-24.13.3"
            {
              typesNode = pkgs.fetchurl {
                url = "https://registry.npmjs.org/@types/node/-/node-24.13.3.tgz";
                hash = "sha512-Dh8vAsV36ig5wa9OX4pXvMc9D3Veibfw2wix0CUwYODLD8nkj9UsLjASr49nPg+2eKzxhBV+v7L8pXvT4e639Q==";
              };
              undiciTypes = pkgs.fetchurl {
                url = "https://registry.npmjs.org/undici-types/-/undici-types-7.18.2.tgz";
                hash = "sha512-AsuCzffGHJybSaRrmr5eHr81mwJU3kjw6M+uprWvCXiNeN9SOGwQ3Jn8jb8m3Z6izVgknn1R0FTCEAP2QrLY/w==";
              };
            } ''
            mkdir -p "$out/node_modules/@types/node" "$out/node_modules/undici-types"
            tar -xzf "$typesNode" -C "$out/node_modules/@types/node" --strip-components=1
            tar -xzf "$undiciTypes" -C "$out/node_modules/undici-types" --strip-components=1
          '';
        in
        {
        default = pkgs.mkShell {
          # The macOS SDK kaya-built guests LINK against (approved
          # 2026-08-16); minos stays 14.0, no darwinMinVersionHook,
          # because SwiftUI reads the sdk field (docs/traps.md). MUST be
          # buildInputs, not packages — packages is mkShell's alias for
          # nativeBuildInputs and the SDK hook then breaks cc outright
          # (docs/chrome/sdk-bump-scout.md §2). The design-generation
          # split is verified by tools/check-design-generation.py.
          buildInputs = [ pkgs.apple-sdk_26 ];
          packages = with pkgs; [
            # LLVM/clang everywhere; Windows builds use the msvc ABI
            # through clang-cl + lld-link via cargo-xwin.
            # The version is EXACT on purpose: `latest` floated with the
            # rust-overlay input, so the compiler moves by editing this
            # line, never by `nix flake update`.
            (rust-bin.stable."1.97.0".default.override {
              targets = [
                "aarch64-pc-windows-msvc"
                "x86_64-pc-windows-msvc"
                "aarch64-apple-ios"
                "aarch64-apple-ios-sim"
                "aarch64-linux-android"
              ];
            })
            rust-analyzer
            rust-cbindgen
            cargo-xwin
            cargo-ndk
            # hatchling + build serve tools/check-wheel.py: the kaya-gui
            # wheel builds offline from the flake's pinned python, never
            # from whatever pip resolves that day.
            (python3.withPackages (ps: [ ps.hatchling ps.build ]))
            # go_1_27 by name: `go` is a major behind, `go_latest` floats
            # on update; lockstep with the Dockerfile and deploy-win pins.
            pkgs.go_1_27
            dotnet-sdk_10
            # OCaml guest (direct ring over ocaml-ctypes + cursor stubs);
            # findlib's setup hook wires OCAMLPATH for the shell.
            ocaml
            dune_3
            ocamlPackages.findlib
            ocamlPackages.ctypes
            ocamlPackages.ctypes-foreign
            ocamlPackages.ppxlib
            # Haskell guest (direct ring; base-only, so bare ghc suffices).
            ghc
            cabal-install
            # node 24 runs the .ts guests directly (type stripping is on
            # by default) and libkaya itself is the N-API addon, so no
            # node-gyp and no second artifact. tsc is the typecheck gate
            # (docs/deferred.md's ninth-binding entry).
            nodejs_24
            typescript
            # Recording mode (KAYA_RECORD=1): screen capture on macOS
            # (avfoundation) and per-step frame extraction everywhere.
            ffmpeg
            # The tools/ scripts are load-bearing validation; lint them.
            shellcheck
            # ruff is shellcheck's opposite number: tools/check-python.py
            # takes three of its rules straight off ruff's (BLE001,
            # S602/S604/S605, PLR1722).
            ruff
            # AddressSanitizer's compiler (see asanClang above):
            # tools/check-c-bounds.py's companion mode, by that name.
            asanClang
            # The Kotlin layer's dead-code gate (tools/check-detekt.py).
            # The compiler cannot serve: K2 moved the UNUSED_*
            # diagnostics into IDE inspections (KT-69698).
            detekt
            # Gradle fetches AGP/Compose from Google Maven at build time.
            androidSdk
            jdk17
            gradle
          ];
          shellHook = ''
            # The tools/ scripts refuse to run unless this marker matches
            # the flake they sit next to, so nothing runs against a dev
            # shell entered before the flake last changed. The scripts
            # recompute it as `cat flake.nix flake.lock | shasum -a 256`.
            export KAYA_DEV_SHELL=${builtins.substring 0 12 (builtins.hashString "sha256" (builtins.readFile ./flake.nix + builtins.readFile ./flake.lock))}
            # Ad-hoc `python3` resolves the kaya package the way the
            # suites do; the runners export their own copy of this.
            export PYTHONPATH="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/bindings/python"
            export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk-bundle"
            # The Android lane's embedded CPython, both ABIs (see
            # cpythonAndroid above).
            export KAYA_CPYTHON_ANDROID_AARCH64="${cpythonAndroidAarch64}"
            export KAYA_CPYTHON_ANDROID_X86_64="${cpythonAndroidX86_64}"
            # The JS typecheck's type roots (see nodeTypes above).
            export KAYA_NODE_TYPES="${nodeTypes}/node_modules/@types"
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # The iOS lane's embedded CPython (see cpythonIos above).
            export KAYA_CPYTHON_IOS="${cpythonIos}/Python.xcframework"
          '';
        };
      });
    };
}
