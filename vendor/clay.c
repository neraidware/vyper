// clay.c — single-TU instantiation of the vendored single-header clay layout
// library. Compiled into the static archive Odin's clay binding links, so the
// shipped binary is built from the committed source (vendor/clay.h), not a
// prebuilt archive. Mirrors how nanosvg.c is treated one directory over.
#define CLAY_IMPLEMENTATION
#include "clay.h"