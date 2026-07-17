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
        in
        {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # Toolchain policy: LLVM/clang everywhere. Windows builds use
            # the msvc ABI through clang-cl + lld-link via cargo-xwin;
            # cl.exe is never required.
            (rust-bin.stable.latest.default.override {
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
            python3
            # Go 1.27rc2, pinned binary distribution: generic methods
            # (type parameters on methods) are foundational for the Go
            # binding's typed surface, and 1.27 is pre-release until
            # August 2026. Swap back to nixpkgs go when it catches up.
            (pkgs.stdenvNoCC.mkDerivation {
              pname = "go";
              version = "1.27rc2";
              src = pkgs.fetchurl {
                url = "https://go.dev/dl/go1.27rc2.darwin-arm64.tar.gz";
                sha256 = "b543bf435ed266d66b275efba433dbe64904be607fe365494cf72f7ad4e91b63";
              };
              sourceRoot = "go";
              dontBuild = true;
              dontFixup = true;
              installPhase = ''
                mkdir -p $out
                cp -R . $out/
                mkdir -p $out/bin
                ln -sf $out/bin/go $out/bin/go || true
              '';
            })
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
            # Recording mode (KAYA_RECORD=1): screen capture on macOS
            # (avfoundation) and per-step frame extraction everywhere.
            ffmpeg
            # The tools/ scripts are load-bearing validation; lint them.
            shellcheck
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
            export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk-bundle"
          '';
        };
      });
    };
}
