#ifndef RUNNER_BACKGROUND_MANAGER_H_
#define RUNNER_BACKGROUND_MANAGER_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <array>
#include <memory>
#include <string>

// Also used by a second launch to activate the existing process.
constexpr UINT kShowHelper = WM_APP + 42;

class BackgroundManager {
 public:
  BackgroundManager(HWND window, flutter::BinaryMessenger* messenger);
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
  bool Apply(const std::array<Shortcut, 2>& shortcuts, bool persist,
             std::string* error);
  bool ReadShortcut(const Value& value, Shortcut* shortcut);
  bool Valid(const Shortcut& shortcut) const;
  Value State() const;
  void Hide();
  void Show();
  void ApplyStyles();

  HWND window_;
  WINDOWPLACEMENT placement_{};
  bool hidden_ = false;
  bool recording_ = false;
  std::array<Binding, 2> bindings_{};
  std::string startup_error_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
};

#endif
