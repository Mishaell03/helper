#ifndef RUNNER_BACKGROUND_MANAGER_H_
#define RUNNER_BACKGROUND_MANAGER_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <array>
#include <memory>
#include <string>
#include "text_automation.h"
#include "startup_visibility.h"
#include "capture_window_parking.h"
#include "task_view_guard.h"
#include "window_watchdog.h"
#include "slot_navigation_policy.h"

// Also used by a second launch to reveal the existing process.
constexpr UINT kShowHelper = WM_APP + 42;
constexpr UINT kRefreshHelperFrame = WM_APP + 44;

class BackgroundManager {
 public:
  BackgroundManager(HWND window, flutter::BinaryMessenger* messenger,
                    bool start_hidden);
  ~BackgroundManager();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  bool keyboard_activation() const { return keyboard_activation_; }

 private:
  struct Shortcut {
    UINT modifiers;
    UINT key;
    bool operator==(const Shortcut& other) const {
      return modifiers == other.modifiers && key == other.key;
    }
  };
  struct Binding {
    Shortcut shortcut;
    int id = 0;
  };
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  static constexpr size_t kActionCount = 5;
  bool Apply(const std::array<Shortcut, kActionCount>& shortcuts, bool persist,
              std::string* error);
  bool ValidAll(const std::array<Shortcut, kActionCount>& shortcuts) const;
  bool DispatchControlHotkey(UINT key, UINT modifiers) const;
  bool SlotWindowVisible() const;
  void UpdateSlotNavigation();
  void DisableSlotNavigation();
  void ReleaseSlotNavigation();
  void RegisterSlotToggle();
  void UpdateViewerEscape();
  void ReleaseViewerEscape();
  bool ViewerEscapeAllowed() const;
  bool ReadShortcut(const Value& value, Shortcut* shortcut);
  bool Valid(const Shortcut& shortcut) const;
  Value State() const;
  void Hide(bool persist_size = true);
  void HideForTaskView();
  bool Show();
  bool ShowCountdownInactive();
  bool ShowWindowSafely();
  bool PreparePresentation();
  void RestoreExternalFocus();
  bool ApplyStyles();
  bool SetKeyboardActivation(bool enabled);
  bool SetAutostart(bool enabled, std::string* error);
  void LoadAutostart();
  void RestoreSize();
  void SaveSize();
  void PickMarkdownFiles(std::unique_ptr<flutter::MethodResult<Value>> result);
  HWND ImportDialogWindow() const;

  HWND window_;
  StartupVisibility visibility_;
  bool hidden_ = true;
  CaptureWindowParking parking_;
  HWND previous_foreground_ = nullptr;
  bool composition_ready_ = false;
  bool recording_ = false;
  bool keyboard_activation_ = false;
  HWND keyboard_previous_foreground_ = nullptr;
  DWORD keyboard_previous_process_ = 0;
  DWORD keyboard_previous_thread_ = 0;
  bool start_hidden_ = false;
  bool autostart_ = false;
  bool prepared_ = false;
  bool exit_requested_ = false;
  Microsoft::WRL::ComPtr<IFileOpenDialog> import_dialog_;
  std::array<Binding, kActionCount> bindings_{};
  SlotNavigationPolicy slot_navigation_;
  bool slot_arrows_registered_ = false;
  bool slot_toggle_registered_ = false;
  bool viewer_escape_requested_ = false;
  bool viewer_escape_registered_ = false;
  std::array<std::string, 2> slot_warnings_{};
  std::string startup_error_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::unique_ptr<TextAutomation> automation_;
  std::unique_ptr<TaskViewGuard> task_view_guard_;
  std::unique_ptr<WindowWatchdog> watchdog_;
  bool in_move_size_loop_ = false;
  HANDLE update_process_ = nullptr;
};

#endif
