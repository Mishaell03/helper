#ifndef RUNNER_WINDOW_COMPOSITION_H_
#define RUNNER_WINDOW_COMPOSITION_H_

#include <windows.h>
#include <string>

// One owner for per-pixel alpha. No Accent/Mica/Acrylic backdrop surfaces.
bool ConfigureTransparentComposition(HWND window, std::string* error);
void FlushHiddenWindowComposition();

#endif  // RUNNER_WINDOW_COMPOSITION_H_
