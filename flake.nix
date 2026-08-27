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
            odin sdl3 sdl3-ttf ffmpeg glslang vulkan-loader pkg-config clang glib.dev
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
           nativeBuildInputs = [ pkgs.odin pkgs.glslang ];
          buildInputs = [ pkgs.sdl3 pkgs.sdl3-ttf pkgs.ffmpeg pkgs.vulkan-loader pkgs.glib ];
           buildPhase = ''
             glslangValidator -V shaders/rounded_rect.vert -o shaders/rounded_rect.vert.spv
             glslangValidator -V shaders/rounded_rect.frag -o shaders/rounded_rect.frag.spv
             glslangValidator -V shaders/text.vert -o shaders/text.vert.spv
             glslangValidator -V shaders/text.frag -o shaders/text.frag.spv
             glslangValidator -V shaders/preview.frag -o shaders/preview.frag.spv
            odin build . -out:nered -extra-linker-flags:"-lgio-2.0 -lglib-2.0"
          '';
          installPhase = ''mkdir -p $out/bin; cp nered $out/bin/'';
        };
      });
    };
}
