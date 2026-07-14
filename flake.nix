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
        }));
    in
    {
      devShells = forAllSystems (pkgs: {
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
              ];
            })
            rust-analyzer
            rust-cbindgen
            cargo-xwin
            # Validation-suite languages (function floor + direct ring tier).
            python3
            go
            dotnet-sdk_10
          ];
        };
      });
    };
}
