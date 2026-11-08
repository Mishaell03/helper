#include "window_watchdog.h"

#include <dwmapi.h>
#include <chrono>
#include <sstream>
#include "capture_diagnostics.h"
#include "responsiveness_policy.h"

namespace {
BOOL CALLBACK CloakThreadWindow(HWND window, LPARAM value) {
  const BOOL cloak = value != 0;
  if (GetAncestor(window, GA_ROOT) == window) {
    DwmSetWindowAttribute(window, DWMWA_CLOAK, &cloak, sizeof(cloak));
  }
  return TRUE;
}
}  // namespace

WindowWatchdog::WindowWatchdog(HWND window)
    : window_(window), window_thread_(GetWindowThreadProcessId(window, nullptr)) {
  NativePulse();
  SetTimer(window_, kWatchdogNativeTimer, 500, nullptr);
  worker_ = std::thread([this]() { Run(); });
}

WindowWatchdog::~WindowWatchdog() {
  KillTimer(window_, kWatchdogNativeTimer);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  stop_.notify_one();
  if (worker_.joinable()) worker_.join();
}

void WindowWatchdog::NativePulse() { native_beat_.store(GetTickCount64()); }

void WindowWatchdog::DartPulse() {
  NativePulse();
  dart_beat_.store(GetTickCount64());
  armed_.store(true); // Never mistake cold engine startup for a hung UI.
}

void WindowWatchdog::SetStage(int stage, int64_t block, int64_t length) {
  stage_.store(stage); block_.store(block); length_.store(length);
  std::ostringstream message;
  message << "block.stage=" << stage << " id=" << block << " length=" << length;
  TraceCaptureNote(message.str());
}

bool WindowWatchdog::AllowReveal() {
  NativePulse();
  if (!tripped_.load()) return true;
  const ULONGLONG now = GetTickCount64();
  if (!acknowledged_.load() || now - dart_beat_.load() > 2000) return false;
  // Only an explicit Show after responsive Dart + native callbacks may uncloak.
  const BOOL cloak = FALSE;
  const HRESULT result = DwmSetWindowAttribute(window_, DWMWA_CLOAK, &cloak, sizeof(cloak));
  if (FAILED(result)) return false;
  EnumThreadWindows(window_thread_, CloakThreadWindow, 0);
  tripped_.store(false);
  acknowledged_.store(false);
  TraceCaptureNote("watchdog.reveal_after_recovery");
  return true;
}

void WindowWatchdog::Run() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stop_.wait_for(lock, std::chrono::milliseconds(250), [this]() { return stopping_; })) {
    lock.unlock();
    const ULONGLONG now = GetTickCount64();
    const ULONGLONG native = native_beat_.load();
    const ULONGLONG dart = dart_beat_.load();
    if (!IsDebuggerPresent() && !tripped_.load() &&
        ResponsivenessTimedOut(now, native, native_dialog_.load() ? native : dart,
                               armed_.load(), visible_.load())) {
      tripped_.store(true);
      acknowledged_.store(false);
      visible_.store(false);
      // FIRST hide, then write diagnostics. Neither operation depends on Dart.
      const BOOL cloak = TRUE;
      const HRESULT result = DwmSetWindowAttribute(window_, DWMWA_CLOAK, &cloak, sizeof(cloak));
      EnumThreadWindows(window_thread_, CloakThreadWindow, 1);
      if (FAILED(result)) ShowWindowAsync(window_, SW_HIDE); // Queued best effort.
      PostMessage(window_, kWatchdogTriggered, 0, 0);
      InitializeCaptureDiagnostics(true);
      std::ostringstream message;
      message << "watchdog.trip native_age_ms=" << (now >= native ? now - native : 0)
              << " dart_age_ms=" << (now >= dart ? now - dart : 0)
              << " block_stage=" << stage_.load() << " block_id=" << block_.load()
              << " length=" << length_.load() << " cloak_hr=" << static_cast<long>(result);
      TraceCaptureFailure(message.str());
    }
    lock.lock();
  }
}
