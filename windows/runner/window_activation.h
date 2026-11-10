#ifndef RUNNER_WINDOW_ACTIVATION_H_
#define RUNNER_WINDOW_ACTIVATION_H_

#include <windows.h>
#include <commctrl.h>

// Flutter's child HWND can handle WM_MOUSEACTIVATE without forwarding it to
// the runner. Consult the owner's live style so explicit keyboard scopes work.
inline LRESULT CALLBACK HelperViewActivationProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR) {
  const HWND root = GetAncestor(window, GA_ROOT);
  if (GetWindowLongPtr(root, GWL_EXSTYLE) & WS_EX_NOACTIVATE) {
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_POINTERACTIVATE) return PA_NOACTIVATE;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, HelperViewActivationProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

#endif  // RUNNER_WINDOW_ACTIVATION_H_
