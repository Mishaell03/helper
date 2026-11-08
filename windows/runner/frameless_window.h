#ifndef RUNNER_FRAMELESS_WINDOW_H_
#define RUNNER_FRAMELESS_WINDOW_H_

#include <windows.h>
#include <optional>

// WS_THICKFRAME is needed by User32's resize loop, but must never be painted.
// DWMNCRP_DISABLED alone does not disable DefWindowProc's classic frame.
inline LONG_PTR FramelessWindowStyle(LONG_PTR style) {
  return (style & ~static_cast<LONG_PTR>(WS_CAPTION)) | WS_THICKFRAME;
}

inline std::optional<LRESULT> HandleFramelessMessage(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_STYLECHANGING:
      if (wparam == static_cast<WPARAM>(GWL_STYLE) && lparam) {
        auto* styles = reinterpret_cast<STYLESTRUCT*>(lparam);
        styles->styleNew = static_cast<DWORD>(FramelessWindowStyle(styles->styleNew));
      }
      break;
    case WM_NCCALCSIZE:
      // Both TRUE (NCCALCSIZE_PARAMS) and FALSE (RECT) use the whole window as
      // client space. Do not let the plugin or DefWindowProc reserve a caption.
      if (lparam && IsZoomed(window)) {
        auto* client = reinterpret_cast<RECT*>(lparam);
        MONITORINFO monitor{};
        monitor.cbSize = sizeof(monitor);
        if (GetMonitorInfoW(MonitorFromRect(client, MONITOR_DEFAULTTONEAREST), &monitor)) {
          *client = monitor.rcWork;
        }
      }
      return 0;
    case WM_NCPAINT:
      return 0; // Flutter owns every pixel, including while User32 is resizing.
  }
  return std::nullopt;
}

#endif  // RUNNER_FRAMELESS_WINDOW_H_
