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
            go
            dotnet-sdk_10
            # OCaml guest (direct ring over ocaml-ctypes + cursor stubs);
            # findlib's setup hook wires OCAMLPATH for the shell.
            ocaml
            ocamlPackages.findlib
            ocamlPackages.ctypes
            ocamlPackages.ctypes-foreign
            # Haskell guest (direct ring; base-only, so bare ghc suffices).
            ghc
            # Android: SDK/emulator/NDK from androidenv; Gradle builds the
            # app shells (fetches AGP/Compose from Google Maven at build time).
            androidSdk
            jdk17
            gradle
          ];
          shellHook = ''
            export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk-bundle"
          '';
        };
      });
    };
}
