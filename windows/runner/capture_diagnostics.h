#ifndef RUNNER_CAPTURE_DIAGNOSTICS_H_
#define RUNNER_CAPTURE_DIAGNOSTICS_H_

#include <windows.h>
#include <string>

DWORD CaptureWindowsBuild();
bool UseStableCaptureSurface();
void InitializeCaptureDiagnostics(bool enabled);
void TraceCapture(const char* event, HWND window, bool hidden, bool parked,
                  DWORD error = ERROR_SUCCESS);
void TraceCaptureFailure(const std::string& message);

#endif  // RUNNER_CAPTURE_DIAGNOSTICS_H_
