#ifndef RUNNER_CAPTURE_EXCLUSION_H_
#define RUNNER_CAPTURE_EXCLUSION_H_

#include <windows.h>

bool ExcludeFromCapture(HWND window, bool refresh_composition = false);

// Best effort for native common-dialog HWNDs owned by this UI thread. Flutter
// routes/dialogs share the main HWND and need no separate window protection.
class CaptureDialogScope {
 public:
  CaptureDialogScope();
  ~CaptureDialogScope();
  CaptureDialogScope(const CaptureDialogScope&) = delete;
  CaptureDialogScope& operator=(const CaptureDialogScope&) = delete;
 private:
  HHOOK hook_ = nullptr;
};

#endif
