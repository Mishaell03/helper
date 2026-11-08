#ifndef RUNNER_WINDOW_WATCHDOG_H_
#define RUNNER_WINDOW_WATCHDOG_H_

#include <windows.h>
#include <atomic>
#include <cstdint>
#include <condition_variable>
#include <mutex>
#include <thread>

constexpr UINT kWatchdogTriggered = WM_APP + 46;
constexpr UINT_PTR kWatchdogNativeTimer = 0x48415409;

// No Flutter calls or window-procedure callbacks from the worker. Emergency
// cloak is requested directly from DWM, even when the window thread is blocked.
class WindowWatchdog {
 public:
  explicit WindowWatchdog(HWND window);
  ~WindowWatchdog();
  void NativePulse();
  void DartPulse();
  void SetVisible(bool visible) { visible_.store(visible); }
  void SetStage(int stage, int64_t block, int64_t length);
  void SetNativeDialogOpen(bool open) {
    native_dialog_.store(open);
    if (!open) dart_beat_.store(GetTickCount64());
  }
  void AcknowledgeHidden() { acknowledged_.store(true); }
  bool AllowReveal();

 private:
  void Run();
  HWND window_;
  DWORD window_thread_;
  std::atomic<ULONGLONG> native_beat_{0};
  std::atomic<ULONGLONG> dart_beat_{0};
  std::atomic<bool> armed_{false};
  std::atomic<bool> visible_{false};
  std::atomic<bool> tripped_{false};
  std::atomic<bool> acknowledged_{false};
  std::atomic<bool> native_dialog_{false};
  std::atomic<int> stage_{0};
  std::atomic<int64_t> block_{0};
  std::atomic<int64_t> length_{0};
  std::mutex mutex_;
  std::condition_variable stop_;
  bool stopping_ = false;
  std::thread worker_;
};

#endif  // RUNNER_WINDOW_WATCHDOG_H_
