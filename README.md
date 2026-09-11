# nered

Editor de clipe de live do neraid

## Desenvolvimento

```sh
nix develop
clang -c -O2 -o vendor/nanosvg/nanosvg.o vendor/nanosvg/nanosvg.c
clang -c -O2 -o clay-odin/linux/clay.o vendor/clay.c
ar rcs clay-odin/linux/clay.a clay-odin/linux/clay.o
odin build .
./nered
```

Clay Odin bindings live in `vendor/clay-odin`. SDL3 GPU owns Vulkan device,
window claim, swapchain, and SDF rectangle/border rendering. SPIR-V binaries are
generated from `shaders/*.vert` and `shaders/*.frag` during Nix builds, and the
vendored nanosvg C renderer (`vendor/nanosvg`, used to draw the UI icons
directly from the `icons/*.svg` files) is compiled to `nanosvg.o`.

## Objetivos

- Rodar em pc merda
- Aguentar vídeos pesados
- Suportar arquivos mp4/av1
- Simples, funcional e objetivo
- Cropping que funciona (INTERATIVO)
- Cropping + Transform (QUE FUNCIONA)
- RENDERIZAÇÃO QUE NAO LOTA O HD
- eventual filtro de cachorro automatico
