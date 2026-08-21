{
  description = "Pure and reproducible overlay for the Kani rust verifier";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    kani-src.url = "git+https://github.com/model-checking/kani?ref=main&rev=e790e830dd9e4ba55a17ce72fd4cea7e4d142e3c&submodules=1";
    kani-src.flake = false;
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    kani-src,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    lib = pkgs.lib;
  in {
    packages.${system} = let
      # Kani pins its nightly in `rust-toolchain.toml` and links against that exact `rustc_driver`;
      # taking the toolchain from the file means it follows the source across bumps instead of
      # having to be tracked by hand.
      rust-toolchain = "${kani-src}/rust-toolchain.toml";
      rustPkgs = pkgs.extend rust-overlay.overlays.default;
    in rec {
      rust = rustPkgs.rust-bin.fromRustupToolchainFile rust-toolchain;

      rustPlatform = rustPkgs.makeRustPlatform {
        cargo = rust;
        rustc = rust;
      };

      kani = let
        kaniVersion = (lib.importTOML "${kani-src}/Cargo.toml").package.version;
        version = "${kaniVersion}-unstable-${kani-src.shortRev}";

        # Fetch external crate dependencies for Kani.
        kaniVendor = rustPlatform.fetchCargoVendor {
          name = "kani-${version}";
          src = kani-src;
          hash = "sha256-LIkxAHdEZehKtaZqMK+s7y3PfMz85c6oxa5MHzo8Fek=";
        };

        # `-Z build-std` recompiles the standard library, whose dependencies live in `rust-src`'s
        # lockfile rather than Kani's.
        toolchainChannel = (lib.importTOML rust-toolchain).toolchain.channel;
        stdVendor = rustPlatform.fetchCargoVendor {
          name = "rust-src-${toolchainChannel}";
          src = "${rust}/lib/rustlib/src/rust/library";
          hash = "sha256-5oJ/mtsJW0R3F7jgxafP23+WMLkyMKu10De5WIzb7Ro=";
        };

        # Cargo can only replace `crates-io` with one directory source, so the two vendor trees have
        # to be flattened into a single one. Kani's is the base: its `Cargo.lock` is the one the
        # setup hook diffs against the source, and it is the one carrying git sources.
        vendor = pkgs.runCommand "kani-${version}-vendor-merged" {} ''
          cp -a ${kaniVendor} $out
          chmod -R u+w $out
          for crate in ${stdVendor}/source-registry-0/*; do
            dest="$out/source-registry-0/$(basename "$crate")"
            # Same crate and version from crates.io either way, so first one wins.
            [ -e "$dest" ] || cp -a "$crate" "$dest"
          done
        '';
      in
        rustPlatform.buildRustPackage {
          pname = "kani";
          inherit version;

          src = kani-src;
          cargoDeps = vendor;

          nativeBuildInputs = [pkgs.makeWrapper];

          # `kani-compiler`'s build script resolves the toolchain it links against as
          # `$RUSTUP_HOME/toolchains/$RUSTUP_TOOLCHAIN`. Pointing the latter at `..`
          # collapses that path back onto the toolchain's own store path, which is how
          # we get away without rustup inside the sandbox.
          env = {
            RUSTUP_HOME = "${rust}";
            RUSTUP_TOOLCHAIN = "..";
            CARGO_NET_OFFLINE = "true";
          };

          # `cargo build-dev` is upstream's own build driver: it builds the binaries
          # into `target/kani/bin`, then uses the freshly built `kani-compiler` to
          # compile Kani's libraries and the standard library into the sysroot.
          buildPhase = ''
            runHook preBuild
            cargo build-dev -- --release
            cargo build --release -p kani-cov
            runHook postBuild
          '';

          # The regression suite drives a complete Kani installation and a set of
          # solvers we do not have here.
          doCheck = false;

          # Lay the sysroot out where the proxies expect to find it, matching the
          # release bundle's structure.
          installPhase = ''
            runHook preInstall

            home="$out/lib/kani-${kaniVersion}"
            mkdir -p "$home" "$out/bin"

            cp -r target/kani/bin "$home/bin"
            cp -r target/kani/lib "$home/lib"
            cp -r target/kani/playback "$home/playback"
            cp -r target/kani/no_core "$home/no_core"
            install -Dm755 target/release/kani-cov "$home/bin/kani-cov"

            # `kani-driver` reads `library/kani/kani_lib.c` out of the installation.
            mkdir -p "$home/library"
            cp -r library/kani library/kani_macros library/std "$home/library/"

            # The proxies prepend this directory to `PATH` before handing off to
            # `kani-driver`, which is how the CPROVER tools get found.
            for tool in ${pkgs.cbmc}/bin/* ${pkgs.kissat}/bin/*; do
              ln -s "$tool" "$home/bin/$(basename "$tool")"
            done

            # `kani-driver` runs `cargo` out of this symlink rather than going through
            # rustup, and reads the channel back from `rust-toolchain-version`.
            ln -s "${rust}" "$home/toolchain"
            printf '%s' "${toolchainChannel}-${pkgs.stdenv.hostPlatform.config}" > "$home/rust-toolchain-version"

            install -Dm755 target/kani/bin/kani "$out/bin/kani"
            install -Dm755 target/kani/bin/cargo-kani "$out/bin/cargo-kani"

            runHook postInstall
          '';

          postFixup = ''
            wrapProgram "$out/bin/kani" --set KANI_HOME "$out/lib"
            wrapProgram "$out/bin/cargo-kani" --set KANI_HOME "$out/lib"
          '';

          meta = {
            description = "Bit-precise model checker for Rust, built from the development branch";
            homepage = "https://github.com/model-checking/kani";
            license = with lib.licenses; [
              mit
              asl20
            ];
            mainProgram = "kani";
            platforms = ["x86_64-linux"];
          };
        };
    };

    overlays.default = final: prev: {
      inherit (self.packages.${prev.stdenv.hostPlatform.system}) kani rust rustPlatform;
    };

    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [
        self.packages.${system}.kani
        self.packages.${system}.rust
      ];
    };
  };
}
