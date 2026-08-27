# nered

Editor de clipe de live do neraid

## Desenvolvimento

```sh
nix develop
odin build .
./nered
```

Clay Odin bindings live in `vendor/clay-odin`. SDL3 GPU owns Vulkan device,
window claim, swapchain, and SDF rectangle/border rendering. SPIR-V binaries are
generated from `shaders/*.vert` and `shaders/*.frag` during Nix builds.

## Objetivos

- Rodar em pc merda
- Aguentar vídeos pesados
- Suportar arquivos mp4/av1
- Simples, funcional e objetivo
- Cropping que funciona (INTERATIVO)
- Cropping + Transform (QUE FUNCIONA)
- RENDERIZAÇÃO QUE NAO LOTA O HD
- eventual filtro de cachorro automatico
