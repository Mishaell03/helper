#include "task_view_guard.h"

#include <array>
#include <utility>
#include "capture_diagnostics.h"

namespace {
constexpr ULONG_PTR kTaskViewInput = 0x48415405;
}  // namespace

TaskViewGuard* TaskViewGuard::instance_ = nullptr;

TaskViewGuard::TaskViewGuard(std::function<void()> before_task_view)
    : before_task_view_(std::move(before_task_view)) {
  instance_ = this;
  chord_.Key(VK_LWIN, (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0);
  chord_.Key(VK_RWIN, (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0);
  hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, GetModuleHandle(nullptr), 0);
}

TaskViewGuard::~TaskViewGuard() {
  if (hook_) UnhookWindowsHookEx(hook_);
  if (instance_ == this) instance_ = nullptr;
}

LRESULT CALLBACK TaskViewGuard::KeyboardHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION && instance_) {
    const auto* event = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    if (event->dwExtraInfo == kTaskViewInput) return CallNextHookEx(nullptr, code, wparam, lparam);
    auto* self = instance_;
    const bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
    const bool task_view = self->chord_.Key(event->vkCode, down);
    if (!down && event->vkCode == VK_TAB && self->swallow_tab_up_) {
      self->swallow_tab_up_ = false;
      return 1;  // The corresponding blocked down was replayed as a full chord.
    }
    if (!down && event->vkCode == self->swallow_win_up_) {
      self->swallow_win_up_ = 0;
      return 1;
    }
    if (task_view && (GetAsyncKeyState(VK_CONTROL) & 0x8000) == 0 &&
        (GetAsyncKeyState(VK_MENU) & 0x8000) == 0) {
      // Hide synchronously BEFORE Windows processes Win+Tab and takes its
      // desktop snapshot. Posting a later hide would race that snapshot.
      self->before_task_view_();
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void TaskViewGuard::ReplaySuppressedChord(UINT win_key) {
  swallow_tab_up_ = true;
  swallow_win_up_ = win_key;
  chord_.Key(win_key, true);
  std::array<INPUT, 4> input{};
  for (auto& event : input) {
    event.type = INPUT_KEYBOARD;
    event.ki.dwExtraInfo = kTaskViewInput;
  }
  input[0].ki.wVk = static_cast<WORD>(win_key);
  input[1].ki.wVk = VK_TAB;
  input[2].ki.wVk = VK_TAB;
  input[2].ki.dwFlags = KEYEVENTF_KEYUP;
  input[3].ki.wVk = static_cast<WORD>(win_key);
  input[3].ki.dwFlags = KEYEVENTF_KEYUP;
  const UINT sent = SendInput(static_cast<UINT>(input.size()), input.data(), sizeof(INPUT));
  if (sent != input.size()) {
    // Only release the synthetic keys whose physical down automation blocked.
    if (sent != 0) SendInput(2, input.data() + 2, sizeof(INPUT));
    TraceCaptureFailure("Win+Tab replay was rejected or partially accepted by Windows.");
  }
}
