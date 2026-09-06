// Single-header SVG renderer (memononen, MIT, stb-based rasterizer).
// One TU instantiates both the parser and rasterizer so the app links only
// nsvgParse/nsvgCreateRasterizer/nsvgRasterize/nsvgDelete{Rasterizer}. The
// placeholders under icons/ are rendered directly at startup (no PNGs).
#define NANOSVG_IMPLEMENTATION
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg.h"
#include "nanosvgrast.h"
