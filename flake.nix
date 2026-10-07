{
  description = "vyper live clip editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            odin sdl3 sdl3-ttf ffmpeg glslang vulkan-loader pkg-config clang glib.dev mold
            xdg-desktop-portal xdg-desktop-portal-gnome
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.vulkan-loader ];
        };
      });

      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "vyper";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.odin pkgs.glslang pkgs.makeWrapper pkgs.llvmPackages.clang ];
          buildInputs = [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.ffmpeg pkgs.vulkan-loader pkgs.glib ];
          buildPhase = ''
            # build.odin owns the steps; this only pins what the nix sandbox
            # needs differently. mold and lld both fail to resolve Odin's
            # absolute -l: namespecs inside the sandbox ("library not found:
            # :/..."); gold does, so the packaged build pins gold. The dev shell
            # keeps mold for everyday local builds.
            VYPER_LINKER=gold ./build.odin release
          '';
          installPhase = ''
            # build.odin does the FHS copy; nix adds the runtime wrapper, which
            # is the one thing it knows and build.odin cannot: the binary links
            # SDL3/vulkan/glib and shells out to ffmpeg, so it cannot run from a
            # bare result/ dir.
            mkdir -p $out/libexec/vyper
            cp target/vyper $out/libexec/vyper/vyper
            wrapProgram $out/libexec/vyper/vyper \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.vulkan-loader pkgs.glib pkgs.ffmpeg ]}" \
              --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]}"
            ln -s $out/libexec/vyper/vyper $out/bin/vyper
            install -Dm644 packaging/vyper.desktop $out/share/applications/vyper.desktop
            install -Dm644 packaging/vyper.svg $out/share/icons/hicolor/scalable/apps/vyper.svg
          '';
          meta = {
            description = "vyper live clip editor";
            mainProgram = "vyper";
          };
        };

        debug = pkgs.stdenv.mkDerivation {
          pname = "vyper-debug";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.odin pkgs.glslang pkgs.makeWrapper pkgs.llvmPackages.clang ];
          buildInputs = [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.ffmpeg pkgs.vulkan-loader pkgs.glib ];
          buildPhase = ''
            # build.odin owns the steps; this only pins what the nix sandbox
            # needs differently. mold and lld both fail to resolve Odin's
            # absolute -l: namespecs inside the sandbox ("library not found:
            # :/..."); gold does, so the packaged build pins gold. The dev shell
            # keeps mold for everyday local builds.
            VYPER_LINKER=gold ./build.odin
          '';
          installPhase = ''
            # build.odin does the FHS copy; nix adds the runtime wrapper, which
            # is the one thing it knows and build.odin cannot: the binary links
            # SDL3/vulkan/glib and shells out to ffmpeg, so it cannot run from a
            # bare result/ dir.
            mkdir -p $out/libexec/vyper
            cp target/vyper $out/libexec/vyper/vyper
            wrapProgram $out/libexec/vyper/vyper \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.vulkan-loader pkgs.glib pkgs.ffmpeg ]}" \
              --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]}"
            ln -s $out/libexec/vyper/vyper $out/bin/vyper
            install -Dm644 packaging/vyper.desktop $out/share/applications/vyper.desktop
            install -Dm644 packaging/vyper.svg $out/share/icons/hicolor/scalable/apps/vyper.svg
          '';
          meta = {
            description = "vyper live clip editor";
            mainProgram = "vyper";
          };
        };
      });
    };
}
