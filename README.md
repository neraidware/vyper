# vyper

Editor de clipe de live do neraid

## Desenvolvimento

```sh
nix develop
./build.odin          # debug, the default
./build.odin release
./build.odin install  # ~/.local by default, or INSTALL_PREFIX=...
./target/vyper
```

Clay Odin bindings live in `vyper/clay-odin`. SDL3 GPU owns Vulkan device,
window claim, swapchain, and SDF rectangle/border rendering. SPIR-V binaries are
generated from `vyper/shaders/*.vert` and `vyper/shaders/*.frag` on every build, and
the vendored nanosvg C renderer (`vyper/vendor/nanosvg`, used to draw the UI icons
directly from the `vyper/icons/*.svg` files) is compiled to `nanosvg.o`.
