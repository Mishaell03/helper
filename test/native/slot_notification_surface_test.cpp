// Windows-only. See docs/windows-testing.md for the build/run command.
#include "../../windows/runner/slot_notification_surface.h"
#include "../../windows/runner/capture_exclusion.h"

#include <cassert>
#include <iostream>

namespace {
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  return DefWindowProcW(window, message, wp, lp);
}
}  // namespace

int main() {
  WNDCLASSW type{};
  type.lpfnWndProc = WindowProc;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"Helper.SlotNotification.SurfaceTest";
  assert(RegisterClassW(&type));
  HWND foreground = GetForegroundWindow();
  HWND window = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
      type.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      type.hInstance, nullptr);
  assert(window);
  DWORD error = ERROR_SUCCESS;
  assert(InitializeSlotNotificationSurface(window, &error));
  const DWORD objects = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  for (int i = 0; i < 32; ++i) {
    assert(InitializeSlotNotificationSurface(window, &error));
    assert(error == ERROR_SUCCESS);
    assert(!IsWindowVisible(window));
    assert(GetForegroundWindow() == foreground);
  }
  assert(GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) == objects);
  RECT rectangle{};
  assert(GetWindowRect(window, &rectangle));
  assert(rectangle.right - rectangle.left == 1);
  assert(rectangle.bottom - rectangle.top == 1);

  // Test the real OS call after the exact blank initialization used in Helper.
  // No content is ever drawn/shown, even if affinity fails on this machine.
  const bool protected_window = ExcludeFromCapture(window, false, &error);
  DWORD affinity = WDA_NONE;
  bool verified = false;
  if (protected_window) {
    if (!GetWindowDisplayAffinity(window, &affinity)) error = GetLastError();
    else if (affinity != WDA_EXCLUDEFROMCAPTURE) error = ERROR_NOT_SUPPORTED;
    else verified = true;
  }
  assert(!IsWindowVisible(window));
  assert(GetForegroundWindow() == foreground);
  DestroyWindow(window);
  UnregisterClassW(type.lpszClassName, type.hInstance);
  if (!verified) {
    std::cerr << "FAIL: protected layered surface is unavailable; Win32=" << error
              << ", affinity=" << affinity << ". No window was shown.\n";
    return 1;
  }
  std::cout << "PASS: blank layered surface initialized before verified affinity; "
               "no show/activation or GDI object leaks\n";
}
