#ifndef RUNNER_TEXT_AUTOMATION_H_
#define RUNNER_TEXT_AUTOMATION_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <array>
#include <functional>
#include <memory>
#include <string>
#include "typing_cadence.h"

// Authoritative state machine on the Windows message thread. No worker thread
// can enqueue keystrokes after Stop: at most ONE Unicode scalar is sent per tick.
class TextAutomation {
 public:
  TextAutomation(HWND window, flutter::BinaryMessenger* messenger,
                 std::function<bool(UINT, UINT)> dispatch_control_hotkey,
                 std::function<bool()> has_emergency_stop,
                 std::function<bool()> show_countdown,
                 std::function<void(UINT, bool)> task_view_requested);
  ~TextAutomation();
  bool HandleMessage(UINT message, WPARAM wparam);
  void RequestStart();
  void TogglePause();
  void Pause(const std::string& reason = "Ввод приостановлен.");
  void Stop(bool notify = true);

 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  enum class Phase { idle, countdown, typing, paused, stopped, completed, error };
  Value Snapshot() const;
  void Notify();
  bool Start(const Map& arguments, std::string* error);
  bool Resume(std::string* error, int seconds = 5);
  void BeginCountdown(bool resume, int seconds);
  void CancelCountdown();
  bool Arm(UINT interval);
  void Tick();
  bool CaptureTarget();
  bool TargetStillFocused() const;
  void CloseTarget();
  bool ObserveInput();
  void RemoveObservers();
  void SendNext();
  void Fail(const std::string& message);
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK MouseHook(int code, WPARAM wparam, LPARAM lparam);
  static TextAutomation* observer_;

  HWND window_;
  HWND target_window_ = nullptr;
  HWND target_focus_ = nullptr;
  DWORD target_process_id_ = 0;
  HANDLE target_process_ = nullptr;
  HHOOK keyboard_hook_ = nullptr;
  HHOOK mouse_hook_ = nullptr;
  std::function<bool(UINT, UINT)> dispatch_control_hotkey_;
  std::array<bool, 256> physical_keys_{};
  std::array<bool, 256> release_passthrough_{};
  std::function<bool()> has_emergency_stop_;
  std::function<bool()> show_countdown_;
  std::function<void(UINT, bool)> task_view_requested_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  Phase phase_ = Phase::idle;
  std::wstring text_;
  size_t offset_ = 0;
  size_t position_ = 0;
  size_t total_ = 0;
  int64_t block_id_ = 0;
  uint64_t revision_ = 0;
  uint64_t stop_generation_ = 0;
  UINT speed_ = 1000;
  TypingCadence cadence_{static_cast<uint32_t>(GetTickCount64()) ^ GetCurrentProcessId()};
  int countdown_ = 0;
  ULONGLONG deadline_ = 0;
  ULONGLONG last_guard_ = 0;
  bool resuming_ = false;
  std::string message_;
};

#endif
