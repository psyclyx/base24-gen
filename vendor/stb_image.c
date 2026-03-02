// Single-file build unit for stb_image.
// Only compiled once; all other TUs include the header without the define.
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
