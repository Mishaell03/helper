#include "capture_exclusion.h"

#include <iostream>

namespace {
LRESULT CALLBACK DialogHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HCBT_CREATEWND || code == HCBT_ACTIVATE) {
    HWND window = reinterpret_cast<HWND>(wparam);
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId() && GetAncestor(window, GA_ROOT) == window) {
      ExcludeFromCapture(window);
      if (code == HCBT_ACTIVATE) {
        if (HWND cancel = GetDlgItem(window, IDCANCEL)) {
          SetWindowTextW(cancel, L"Отмена");
        }
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}
}  // namespace

bool ExcludeFromCapture(HWND window, bool refresh_composition) {
  constexpr DWORD kExcludeFromCapture = 0x00000011;  // WDA_EXCLUDEFROMCAPTURE
  DWORD current = WDA_NONE;
  if (!refresh_composition && GetWindowDisplayAffinity(window, &current) &&
      current == kExcludeFromCapture) {
    return true;  // Do not rebuild DWM's protection state on each Show/Hide.
  }
  if (SetWindowDisplayAffinity(window, kExcludeFromCapture)) return true;
  std::cerr << "Не удалось исключить окно из захвата экрана. Код Win32: "
            << GetLastError() << std::endl;
  return false;
}

CaptureDialogScope::CaptureDialogScope() {
  // Thread-local, not a system-wide hook; it exists only while the picker is up.
  hook_ = SetWindowsHookExW(WH_CBT, DialogHook, nullptr, GetCurrentThreadId());
  if (!hook_) {
    std::cerr << "Не удалось настроить исключение диалога импорта из захвата. Код Win32: "
              << GetLastError() << std::endl;
  }
}

CaptureDialogScope::~CaptureDialogScope() {
  if (hook_) UnhookWindowsHookEx(hook_);
}
