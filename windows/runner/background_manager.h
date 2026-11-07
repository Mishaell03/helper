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

// Also used by a second launch to activate the existing process.
constexpr UINT kShowHelper = WM_APP + 42;

class BackgroundManager {
 public:
  BackgroundManager(HWND window, flutter::BinaryMessenger* messenger,
                    bool start_hidden);
  ~BackgroundManager();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

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
  bool IsControlHotkey(UINT key) const;
  bool ReadShortcut(const Value& value, Shortcut* shortcut);
  bool Valid(const Shortcut& shortcut) const;
  Value State() const;
  void Hide();
  bool Show();
  bool ShowCountdownInactive();
  bool ApplyStyles();
  bool SetAutostart(bool enabled, std::string* error);
  void LoadAutostart();
  void RestoreSize();
  void SaveSize();
  void PickMarkdownFiles(std::unique_ptr<flutter::MethodResult<Value>> result);
  HWND ImportDialogWindow() const;

  HWND window_;
  WINDOWPLACEMENT placement_{};
  bool hidden_ = false;
  bool recording_ = false;
  bool start_hidden_ = false;
  bool autostart_ = false;
  bool prepared_ = false;
  bool exit_requested_ = false;
  Microsoft::WRL::ComPtr<IFileOpenDialog> import_dialog_;
  std::array<Binding, kActionCount> bindings_{};
  std::string startup_error_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::unique_ptr<TextAutomation> automation_;
};

#endif
