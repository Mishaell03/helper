// Windows-only: real HWND, production non-client handling, no Flutter needed.
#include "../../windows/runner/frameless_window.h"

#include <cassert>
#include <iostream>

LRESULT CALLBACK FrameTestProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (const auto result = HandleFramelessMessage(window, message, wp, lp)) {
    return *result;
  }
  if (message == WM_NCACTIVATE) return TRUE;
  return DefWindowProcW(window, message, wp, lp);
}

void CheckFrame(HWND window) {
  const LONG_PTR style = GetWindowLongPtrW(window, GWL_STYLE);
  assert((style & WS_CAPTION) == 0);
  assert((style & WS_THICKFRAME) != 0);
  RECT outer{}, client{};
  assert(GetWindowRect(window, &outer));
  assert(GetClientRect(window, &client));
  POINT origin{};
  assert(ClientToScreen(window, &origin));
  assert(origin.x == outer.left && origin.y == outer.top);
  assert(client.right == outer.right - outer.left);
  assert(client.bottom == outer.bottom - outer.top);
}

int main() {
  WNDCLASSW type{};
  type.lpfnWndProc = FrameTestProc;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"Helper.Frameless.RegressionTest";
  assert(RegisterClassW(&type));
  HWND window = CreateWindowExW(0, type.lpszClassName, L"Test",
      static_cast<DWORD>(FramelessWindowStyle(WS_OVERLAPPEDWINDOW)),
      20, 20, 500, 400, nullptr, nullptr, type.hInstance, nullptr);
  assert(window);
  CheckFrame(window);
  SendMessageW(window, WM_ENTERSIZEMOVE, 0, 0);
  for (int step = 0; step < 30; ++step) {
    // Even an attempt to restore the normal style cannot restore the caption.
    SetWindowLongPtrW(window, GWL_STYLE,
        GetWindowLongPtrW(window, GWL_STYLE) | WS_CAPTION);
    assert(SetWindowPos(window, nullptr, 20, 20, 500 + step, 400 + step,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED));
    CheckFrame(window);
    RECT simple{20, 20, 520 + step, 420 + step};
    assert(SendMessageW(window, WM_NCCALCSIZE, FALSE,
        reinterpret_cast<LPARAM>(&simple)) == 0);
    assert(simple.left == 20 && simple.top == 20);
    assert(simple.right == 520 + step && simple.bottom == 420 + step);
    assert(SendMessageW(window, WM_NCPAINT, 1, 0) == 0);
    assert(SendMessageW(window, WM_NCACTIVATE, TRUE, 0) == TRUE);
  }
  SendMessageW(window, WM_EXITSIZEMOVE, 0, 0);
  CheckFrame(window);
  DestroyWindow(window);
  UnregisterClassW(type.lpszClassName, type.hInstance);
  std::cout << "PASS: no caption or non-client inset during repeated native resize/style changes\n";
}
