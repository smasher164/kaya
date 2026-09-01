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
          # SDK + emulator + NDK for the Android leg. Versions ride
          # androidenv's defaults except where a component must be pinned to
          # exist in its package set.
          androidSdk = (pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "35" ];
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ "arm64-v8a" ];
            includeNDK = true;
          }).androidsdk;
          # THE SANITIZER COMPILER, under a name of its own. Every nixpkgs
          # llvm below 22 has an ASan that cannot start on this host: an
          # -fsanitize=address binary hangs before main in a reentrant
          # malloc inside shadow-memory init, with no report and no flag
          # that helps (measured across 18/19/20/21; docs/traps.md).
          # 22.1.8 carries the upstream fixes and is already at the
          # nixpkgs rev flake.lock pins, so this costs no input bump.
          #
          # NOT a second devShell: every gate runs inside the ONE shell
          # the lanes enter, and a gate that needs a different `nix
          # develop` is a guard someone has to remember (invariant 3).
          # NOT a second `clang` on PATH either — whichever won would be a
          # PATH-ordering accident, and a probe that compiled with 21.1.8
          # would HANG for its whole ceiling instead of failing. So
          # `clang` keeps meaning this shell's 21.1.8, nothing kaya ships
          # moves, and tools/check-c-bounds.sh asks for this name.
          asanClang = pkgs.runCommand "kaya-asan-clang" { } ''
            mkdir -p "$out/bin"
            ln -s ${pkgs.llvmPackages_22.clang}/bin/clang "$out/bin/kaya-asan-clang"
          '';
          # CPython for the iOS lane (docs/python-mobile-plan.md §D1):
          # python.org's official XCframework, pinned HERE and not by a
          # fetch script — the store's content addressing IS the hash
          # check, the dev-shell fingerprint moves when this pin moves,
          # and check-pins has nothing to hold (a structural guard
          # outranks a gate, invariant 3). 3.15.0rc1 until the final
          # lands (scheduled 2026-10-01). Exported darwin-only in the
          # shellHook so a linux `nix develop` never pays an 84 MB
          # fetch it cannot use.
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
          # The Android halves of the same pin (docs/python-mobile-plan.md
          # §D1): python.org's official embeddable packages, one per ABI —
          # arm64-v8a for the phones and Apple Silicon emulators, x86_64
          # for Intel-host emulators — both shipped in the APK's jniLibs
          # so the artifact runs on either (the probe report's §6 note).
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
          # Node's type declarations for the JS typecheck gate
          # (tools/js-typecheck.sh): nixpkgs carries no @types/node, so
          # the two npm tarballs are pinned HERE like the CPython
          # archives above — the store's content addressing is the hash
          # check, the dev-shell fingerprint moves when the pin moves,
          # and check-pins has nothing to hold. undici-types is
          # @types/node's one dependency (its fetch globals). Laid out
          # as a node_modules tree so the bare import inside @types/node
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
          # 2026-08-16): sdk 26.5 opts their main executables into
          # macOS 26's modern design generation, while minos stays 14.0
          # (no darwinMinVersionHook on purpose — SwiftUI reads the sdk
          # field, not minos; docs/traps.md), so macOS 14/15 stay run
          # targets. MUST be buildInputs, not packages: packages is
          # mkShell's alias for nativeBuildInputs (the build role), and
          # the SDK hook then clashes with the stdenv's 14.4 and breaks
          # cc outright — loud, measured twice (the scout report,
          # docs/chrome/sdk-bump-scout.md §2).
          #
          # THE DESIGN-GENERATION SPLIT this chooses (the ledger's
          # standing constraint, docs/deferred.md): MODERN = the legs
          # whose main executable this shell links — rust, go, c,
          # ocaml, haskell — plus swift, which compiles against the
          # system toolchain and was modern already. COMPAT = the legs
          # whose main executable is a vendor-stamped host kaya does
          # not link — python (14.4), C#/.NET (14.4), java/zulu (11.3)
          # — OBSERVED coverage, not chosen, so the gate
          # (tools/check-design-generation.sh) verifies both sides
          # non-empty on every sweep rather than trusting this comment.
          buildInputs = [ pkgs.apple-sdk_26 ];
          packages = with pkgs; [
            # Toolchain policy: LLVM/clang everywhere. Windows builds use
            # the msvc ABI through clang-cl + lld-link via cargo-xwin;
            # cl.exe is never required.
            # Exact on purpose (2026-08-31): `latest` floated with the
            # rust-overlay input, so an input update to fix overlay
            # packaging would bump rustc as a side effect. The compiler
            # moves by editing this version, never by `nix flake update`.
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
            # Validation-suite languages (function floor + direct ring tier).
            # hatchling + build serve tools/check-wheel.sh: the kaya-gui
            # wheel builds offline (--no-isolation) from the flake's
            # pinned python, never from whatever pip resolves that day.
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
            # The JS guest (docs/deferred.md's ninth-binding entry): node
            # 24 runs the .ts guests directly — type stripping is on by
            # default there, and tsconfig's erasableSyntaxOnly keeps the
            # sources inside what it strips — and libkaya itself is the
            # N-API addon (crates/kaya/src/node.rs), so no node-gyp, no
            # node headers, no second artifact. tsc is the typecheck
            # gate (tools/js-typecheck.sh); npm rides in with node and
            # links the workspaces offline.
            nodejs_24
            typescript
            # Recording mode (KAYA_RECORD=1): screen capture on macOS
            # (avfoundation) and per-step frame extraction everywhere.
            ffmpeg
            # The tools/ scripts are load-bearing validation; lint them.
            shellcheck
            # The gate bodies are python now (docs/deferred.md's ruling,
            # 2026-08-27) and ruff is shellcheck's opposite number:
            # tools/check-python.py runs it over tools/lib and every
            # converted gate, and takes three of its eight rules straight
            # off ruff's (BLE001 swallowed exceptions, S602/S604/S605
            # shell=True, PLR1722 exit()). From the pinned nixpkgs like
            # everything else here — no network resolution of its own, so
            # check-pins has nothing to hold.
            ruff
            # AddressSanitizer's compiler (see asanClang above):
            # tools/check-c-bounds.sh's companion mode, by that name.
            asanClang
            # The Kotlin layer's dead-code gate (tools/check-detekt.sh).
            # The compiler cannot serve here: K2 moved the UNUSED_*
            # diagnostics into IDE inspections (KT-69698), so a dead
            # local compiles clean.
            detekt
            # Android: SDK/emulator/NDK from androidenv; Gradle builds the
            # app shells (fetches AGP/Compose from Google Maven at build time).
            androidSdk
            jdk17
            gradle
          ];
          shellHook = ''
            # The tools/ scripts refuse to run unless this marker
            # matches the flake they sit next to: everything runs against
            # the flake's pinned toolchains, never a bystander rustc or a
            # dev shell entered before the flake last changed. The value
            # fingerprints flake.nix+flake.lock (the scripts recompute it
            # with `cat flake.nix flake.lock | shasum -a 256`).
            export KAYA_DEV_SHELL=${builtins.substring 0 12 (builtins.hashString "sha256" (builtins.readFile ./flake.nix + builtins.readFile ./flake.lock))}
            # Ad-hoc `python3` in the shell resolves the kaya package the
            # same way the suites do (the runners export their own copy
            # of this; the shellHook covers everything run by hand).
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
