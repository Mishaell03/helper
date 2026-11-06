#include "background_manager.h"

#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cstdint>
#include <vector>

namespace {
constexpr wchar_t kSettingsPath[] = L"Software\\Helper\\Hotkeys";
constexpr wchar_t kSettingsValue[] = L"BindingsV1";
std::string WinError(const char* operation, DWORD error) {
  return std::string(operation) + " (Win32 " + std::to_string(error) + ")";
}
}  // namespace

BackgroundManager::BackgroundManager(HWND window,
                                     flutter::BinaryMessenger* messenger)
    : window_(window) {
  placement_.length = sizeof(placement_);
  ApplyStyles();
  std::array<Shortcut, 2> shortcuts = {{{MOD_CONTROL | MOD_SHIFT, VK_F12},
                                     {MOD_CONTROL | MOD_SHIFT, VK_F11}}};
  DWORD data[4]{};
  DWORD size = sizeof(data);
  const LSTATUS read = RegGetValueW(HKEY_CURRENT_USER, kSettingsPath,
      kSettingsValue, RRF_RT_REG_BINARY, nullptr, data, &size);
  if (read == ERROR_SUCCESS && size == sizeof(data) &&
      Valid({data[0], data[1]}) && Valid({data[2], data[3]}) &&
      !(Shortcut{data[0], data[1]} == Shortcut{data[2], data[3]})) {
    shortcuts = {{{data[0], data[1]}, {data[2], data[3]}}};
  } else if (read != ERROR_FILE_NOT_FOUND && read != ERROR_PATH_NOT_FOUND) {
    startup_error_ = "Could not read valid hotkey settings; using defaults. ";
  }
  std::string error;
  if (!Apply(shortcuts, false, &error)) {
    // Do not silently change persisted shortcuts or leave only one registered.
    bindings_[0].shortcut = shortcuts[0];
    bindings_[1].shortcut = shortcuts[1];
    startup_error_ += error + ". Hotkeys inactive; choose new combinations.";
  }

  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "helper/background", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getSettings") {
      result->Success(State());
    } else if (method == "saveSettings") {
      const auto* map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      std::array<Shortcut, 2> shortcuts{};
      if (!map || map->count(Value("toggle")) == 0 ||
          map->count(Value("exit")) == 0 ||
          !ReadShortcut(map->at(Value("toggle")), &shortcuts[0]) ||
          !ReadShortcut(map->at(Value("exit")), &shortcuts[1])) {
        result->Error("invalid_hotkey", "Use modifiers and a supported keyboard key.");
        return;
      }
      std::string error;
      if (!Apply(shortcuts, true, &error)) {
        result->Error("hotkey_error", error);
      } else {
        startup_error_.clear();
        result->Success(State());
      }
    } else if (method == "setRecording") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) {
        result->Error("invalid_argument", "Expected boolean.");
        return;
      }
      recording_ = *enabled;
      result->Success();
    } else if (method == "hide") {
      Hide();
      result->Success();
    } else if (method == "show") {
      Show();
      result->Success();
    } else if (method == "exit") {
      result->Success();
      // Post rather than destroy the messenger during its own callback.
      PostMessage(window_, WM_APP + 43, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
}

BackgroundManager::~BackgroundManager() {
  channel_->SetMethodCallHandler(nullptr);
  for (const auto& binding : bindings_) {
    if (binding.id) UnregisterHotKey(window_, binding.id);
  }
}

bool BackgroundManager::Valid(const Shortcut& shortcut) const {
  const UINT key = shortcut.key;
  const bool supported = (key >= 'A' && key <= 'Z') ||
      (key >= '0' && key <= '9') || (key >= VK_F1 && key <= VK_F24) ||
      (key >= VK_NUMPAD0 && key <= VK_DIVIDE) ||
      (key >= VK_PRIOR && key <= VK_DOWN) || key == VK_SPACE ||
      key == VK_RETURN || key == VK_TAB || key == VK_BACK ||
      key == VK_INSERT || key == VK_DELETE ||
      (key >= VK_OEM_1 && key <= VK_OEM_3) ||
      (key >= VK_OEM_4 && key <= VK_OEM_8) || key == VK_OEM_102;
  return supported && shortcut.modifiers != 0 &&
      (shortcut.modifiers & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) == 0;
}

bool BackgroundManager::ReadShortcut(const Value& value, Shortcut* shortcut) {
  const auto* map = std::get_if<Map>(&value);
  if (!map) return false;
  const auto modifiers = map->find(Value("modifiers"));
  const auto key = map->find(Value("key"));
  if (modifiers == map->end() || key == map->end()) return false;
  const auto* m = std::get_if<int32_t>(&modifiers->second);
  const auto* k = std::get_if<int32_t>(&key->second);
  if (!m || !k || *m < 0 || *k < 0) return false;
  *shortcut = {static_cast<UINT>(*m), static_cast<UINT>(*k)};
  return Valid(*shortcut);
}

bool BackgroundManager::Apply(const std::array<Shortcut, 2>& shortcuts,
                              bool persist, std::string* error) {
  if (!Valid(shortcuts[0]) || !Valid(shortcuts[1]) || shortcuts[0] == shortcuts[1]) {
    *error = "Shortcuts must be valid and different, with at least one modifier.";
    return false;
  }
  // Keep old registrations until BOTH new shortcuts and persistence succeed.
  // Reuse matching registrations, including when the two actions are swapped.
  std::array<Binding, 2> next{};
  std::vector<int> acquired;
  auto rollback = [&]() {
    for (int id : acquired) UnregisterHotKey(window_, id);
  };
  for (size_t i = 0; i < next.size(); ++i) {
    next[i].shortcut = shortcuts[i];
    for (const auto& old : bindings_) {
      if (old.id && old.shortcut == shortcuts[i]) next[i].id = old.id;
    }
    if (next[i].id) continue;
    int id = 1;
    while (std::any_of(bindings_.begin(), bindings_.end(),
                      [id](const Binding& b) { return b.id == id; }) ||
           std::find(acquired.begin(), acquired.end(), id) != acquired.end()) ++id;
    if (!RegisterHotKey(window_, id, shortcuts[i].modifiers | MOD_NOREPEAT,
                        shortcuts[i].key)) {
      *error = WinError(i == 0 ? "Toggle shortcut unavailable" : "Exit shortcut unavailable",
                        GetLastError());
      rollback();
      return false;
    }
    acquired.push_back(id);
    next[i].id = id;
  }
  if (persist) {
    HKEY key = nullptr;
    LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsPath, 0, nullptr,
        0, KEY_SET_VALUE, nullptr, &key, nullptr);
    if (status == ERROR_SUCCESS) {
      const DWORD data[] = {shortcuts[0].modifiers, shortcuts[0].key,
                            shortcuts[1].modifiers, shortcuts[1].key};
      status = RegSetValueExW(key, kSettingsValue, 0, REG_BINARY,
          reinterpret_cast<const BYTE*>(data), sizeof(data));
      RegCloseKey(key);
    }
    if (status != ERROR_SUCCESS) {
      *error = WinError("Could not save settings", status);
      rollback();
      return false;
    }
  }
  for (const auto& old : bindings_) {
    if (old.id && old.id != next[0].id && old.id != next[1].id)
      UnregisterHotKey(window_, old.id);
  }
  bindings_ = next;
  return true;
}

BackgroundManager::Value BackgroundManager::State() const {
  auto encode = [](const Shortcut& shortcut) {
    return Value(Map{{Value("modifiers"), Value(static_cast<int32_t>(shortcut.modifiers))},
                     {Value("key"), Value(static_cast<int32_t>(shortcut.key))}});
  };
  return Value(Map{{Value("toggle"), encode(bindings_[0].shortcut)},
                   {Value("exit"), encode(bindings_[1].shortcut)},
                   {Value("active"), Value(bindings_[0].id != 0 && bindings_[1].id != 0)},
                   {Value("warning"), Value(startup_error_)}});
}

void BackgroundManager::ApplyStyles() {
  const LONG_PTR styles = GetWindowLongPtr(window_, GWL_EXSTYLE);
  SetWindowLongPtr(window_, GWL_EXSTYLE,
                   (styles | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void BackgroundManager::Hide() {
  if (hidden_) return;
  GetWindowPlacement(window_, &placement_);
  hidden_ = true;
  ShowWindow(window_, SW_HIDE);
}

void BackgroundManager::Show() {
  ApplyStyles();
  if (hidden_) {
    SetWindowPlacement(window_, &placement_);
    hidden_ = false;
  }
  ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

bool BackgroundManager::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CLOSE) {
    Hide();
    return true;
  }
  if (message == kShowHelper) {
    Show();
    return true;
  }
  if (message == WM_APP + 43) {
    DestroyWindow(window_);
    return true;
  }
  if (message != WM_HOTKEY) return false;
  // Ignore stale queued messages after reconfiguration.
  for (size_t i = 0; i < bindings_.size(); ++i) {
    const auto& b = bindings_[i];
    if (!b.id || wparam != static_cast<WPARAM>(b.id) ||
        LOWORD(lparam) != b.shortcut.modifiers || HIWORD(lparam) != b.shortcut.key)
      continue;
    if (recording_) {
      channel_->InvokeMethod("recorded", std::make_unique<Value>(Map{
          {Value("modifiers"), Value(static_cast<int32_t>(b.shortcut.modifiers))},
          {Value("key"), Value(static_cast<int32_t>(b.shortcut.key))}}));
    } else if (i == 0) {
      if (IsWindowVisible(window_) && !IsIconic(window_)) Hide(); else Show();
    } else {
      PostMessage(window_, WM_APP + 43, 0, 0);
    }
    break;
  }
  return true;
}
