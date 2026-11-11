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
void TraceCaptureNote(const std::string& message);
std::string CaptureErrorMessage(DWORD error);
void TraceCaptureApi(const char* operation, HWND window, bool success,
                     DWORD error = ERROR_SUCCESS, HRESULT result = S_OK);

#endif  // RUNNER_CAPTURE_DIAGNOSTICS_H_
