{
  description = "nered live clip editor";

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
          pname = "nered";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.odin pkgs.glslang pkgs.makeWrapper pkgs.llvmPackages.clang ];
          buildInputs = [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.ffmpeg pkgs.vulkan-loader pkgs.glib ];
          buildPhase = ''
            # Odin links its static vendor archives (clay-odin, vendored
            # stb/truetype) as -l:/abs/path GNU "namespec" arguments. The mold
            # manpage documents plain `-l libname` only -- it has no reference
            # to the GNU -l:filename namespec extension, and no default search
            # paths ("Unlike the GNU linkers, mold does not have default search
            # paths"). In practice mold/lld both fail to resolve odin's absolute
            # -l: namespecs inside the nix sandbox ("library not found: :/...").
            # gold (GNU binutils) resolves them, so the packaged build uses gold.
            # The dev shell keeps mold for everyday local builds.
            glslangValidator -V shaders/rounded_rect.vert -o shaders/rounded_rect.vert.spv
            glslangValidator -V shaders/rounded_rect.frag -o shaders/rounded_rect.frag.spv
            glslangValidator -V shaders/text.vert -o shaders/text.vert.spv
            glslangValidator -V shaders/text.frag -o shaders/text.frag.spv
            glslangValidator -V shaders/preview.frag -o shaders/preview.frag.spv
            clang -c -O2 -o vendor/nanosvg/nanosvg.o vendor/nanosvg/nanosvg.c
            odin build . -out:nered \
              -microarch:native -o:aggressive -no-bounds-check \
              -strict-style -vet-using-param -vet-using-stmt \
              -extra-linker-flags:"-fuse-ld=gold -lgio-2.0 -lglib-2.0"
          '';
          # The binary is linked against SDL3/SDL3_ttf/vulkan-loader + the
          # ffmpeg libs and shells out to ffmpeg for proxy transcode, so it
          # can't be run from a bare result/ dir. Keep the real binary under
          # libexec, wrap it with the needed runtime lib path + ffmpeg on
          # PATH, and expose the wrapper as bin/nered. The .desktop entry and
          # icon ship in share/ so environment.systemPackages (or home-manager)
          # pick them up for the app menu.
          installPhase = ''
            mkdir -p $out/bin $out/libexec/nered
            cp nered $out/libexec/nered/nered
            wrapProgram $out/libexec/nered/nered \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.vulkan-loader pkgs.glib pkgs.ffmpeg ]}" \
              --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]}"
            ln -s $out/libexec/nered/nered $out/bin/nered
            install -Dm644 packaging/nered.desktop $out/share/applications/nered.desktop
            install -Dm644 packaging/nered.svg $out/share/icons/hicolor/scalable/apps/nered.svg
          '';
          meta = {
            description = "nered live clip editor";
            mainProgram = "nered";
          };
        };

        debug = pkgs.stdenv.mkDerivation {
          pname = "nered-debug";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.odin pkgs.glslang pkgs.makeWrapper pkgs.llvmPackages.clang ];
          buildInputs = [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.ffmpeg pkgs.vulkan-loader pkgs.glib ];
          buildPhase = ''
            # Odin links its static vendor archives (clay-odin, vendored
            # stb/truetype) as -l:/abs/path GNU "namespec" arguments. The mold
            # manpage documents plain `-l libname` only -- it has no reference
            # to the GNU -l:filename namespec extension, and no default search
            # paths ("Unlike the GNU linkers, mold does not have default search
            # paths"). In practice mold/lld both fail to resolve odin's absolute
            # -l: namespecs inside the nix sandbox ("library not found: :/...").
            # gold (GNU binutils) resolves them, so the packaged build uses gold.
            # The dev shell keeps mold for everyday local builds.
            glslangValidator -V shaders/rounded_rect.vert -o shaders/rounded_rect.vert.spv
            glslangValidator -V shaders/rounded_rect.frag -o shaders/rounded_rect.frag.spv
            glslangValidator -V shaders/text.vert -o shaders/text.vert.spv
            glslangValidator -V shaders/text.frag -o shaders/text.frag.spv
            glslangValidator -V shaders/preview.frag -o shaders/preview.frag.spv
            clang -c -O2 -o vendor/nanosvg/nanosvg.o vendor/nanosvg/nanosvg.c
            odin build . -out:nered \
              -debug \
              -vet-style -vet-semicolon \
              -extra-linker-flags:"-fuse-ld=gold -lgio-2.0 -lglib-2.0"
          '';
          # The binary is linked against SDL3/SDL3_ttf/vulkan-loader + the
          # ffmpeg libs and shells out to ffmpeg for proxy transcode, so it
          # can't be run from a bare result/ dir. Keep the real binary under
          # libexec, wrap it with the needed runtime lib path + ffmpeg on
          # PATH, and expose the wrapper as bin/nered. The .desktop entry and
          # icon ship in share/ so environment.systemPackages (or home-manager)
          # pick them up for the app menu.
          installPhase = ''
            mkdir -p $out/bin $out/libexec/nered
            cp nered $out/libexec/nered/nered
            wrapProgram $out/libexec/nered/nered \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.vulkan-loader pkgs.glib pkgs.ffmpeg ]}" \
              --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]}"
            ln -s $out/libexec/nered/nered $out/bin/nered
            install -Dm644 packaging/nered.desktop $out/share/applications/nered.desktop
            install -Dm644 packaging/nered.svg $out/share/icons/hicolor/scalable/apps/nered.svg
          '';
          meta = {
            description = "nered live clip editor";
            mainProgram = "nered";
          };
        };
      });
    };
}
