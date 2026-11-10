// Windows-only: cl /EHsc test\native\window_activation_test.cpp user32.lib comctl32.lib
#include "../../windows/runner/window_activation.h"

#include <cassert>
#include <iostream>

namespace {
int clicks = 0;
LRESULT CALLBACK ViewProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_MOUSEACTIVATE) return MA_ACTIVATE;
  if (message == WM_POINTERACTIVATE) return PA_ACTIVATE;
  if (message == WM_LBUTTONDOWN) ++clicks;
  return DefWindowProcW(window, message, wp, lp);
}
}  // namespace

int main() {
  WNDCLASSW type{};
  type.lpfnWndProc = ViewProc;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"Helper.Activation.RegressionTest";
  assert(RegisterClassW(&type));
  HWND owner = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      type.lpszClassName, L"Owner", WS_OVERLAPPEDWINDOW,
      20, 20, 400, 300, nullptr, nullptr, type.hInstance, nullptr);
  assert(owner);
  HWND child = CreateWindowExW(0, type.lpszClassName, L"View", WS_CHILD,
      0, 0, 400, 300, owner, nullptr, type.hInstance, nullptr);
  assert(child);
  assert(SetWindowSubclass(child, HelperViewActivationProc, 0, 0));
  for (int cycle = 0; cycle < 10; ++cycle) {
    assert(SendMessageW(child, WM_MOUSEACTIVATE, 0, 0) == MA_NOACTIVATE);
    assert(SendMessageW(child, WM_POINTERACTIVATE, 0, 0) == PA_NOACTIVATE);
    SendMessageW(child, WM_LBUTTONDOWN, 0, 0);
    const LONG_PTR styles = GetWindowLongPtrW(owner, GWL_EXSTYLE);
    SetWindowLongPtrW(owner, GWL_EXSTYLE,
        styles & ~static_cast<LONG_PTR>(WS_EX_NOACTIVATE));
    assert(SendMessageW(child, WM_MOUSEACTIVATE, 0, 0) == MA_ACTIVATE);
    assert(SendMessageW(child, WM_POINTERACTIVATE, 0, 0) == PA_ACTIVATE);
    SetWindowLongPtrW(owner, GWL_EXSTYLE, styles);
    ShowWindow(owner, SW_SHOWNOACTIVATE);
    ShowWindow(owner, SW_HIDE);
    assert(GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_TOOLWINDOW);
  }
  assert(clicks == 10);
  DestroyWindow(owner);  // Also exercises subclass cleanup on child destruction.
  UnregisterClassW(type.lpszClassName, type.hInstance);
  std::cout << "PASS: child activation policy, keyboard scopes and pointer delivery\n";
}
