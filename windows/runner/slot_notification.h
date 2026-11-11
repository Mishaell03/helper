#ifndef RUNNER_SLOT_NOTIFICATION_H_
#define RUNNER_SLOT_NOTIFICATION_H_

#include <windows.h>
#include <functional>
#include <string>

#include "slot_notification_policy.h"

// One UI-thread-owned HWND. Selection remains exclusively in Flutter.
class SlotNotification {
 public:
  explicit SlotNotification(std::function<void(const std::string&)> warning);
  ~SlotNotification();
  SlotNotification(const SlotNotification&) = delete;
  SlotNotification& operator=(const SlotNotification&) = delete;
  bool enabled() const { return enabled_; }
  const std::string& warning() const { return warning_; }
  bool SetEnabled(bool enabled, std::string* error);
  void SelectionChanged(int64_t id, const std::wstring& name, bool main_visible);
  void Dismiss();

 private:
  struct SavedPosition {
    DWORD version = 1;
    wchar_t monitor[CCHDEVICENAME]{};
    LONG x = 0; // DIPs relative to this monitor's work area.
    LONG y = 0;
  };
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wp, LPARAM lp);
  LRESULT HandleMessage(UINT message, WPARAM wp, LPARAM lp);
  bool Create();
  bool Protect();
  void ProtectionFailed();
  bool Render(HMONITOR monitor, const POINT* position = nullptr);
  HMONITOR TargetMonitor() const;
  void RefreshPosition();
  void LoadSettings();
  void SavePosition();
  void Fail(const std::string& message);

  HWND window_ = nullptr;
  ATOM window_class_ = 0;
  ULONG_PTR graphics_token_ = 0;
  DWORD capture_error_ = ERROR_SUCCESS;
  bool enabled_ = true;
  bool have_position_ = false;
  SavedPosition position_;
  SlotNotificationLifetime lifetime_;
  std::wstring text_;
  std::string warning_;
  std::function<void(const std::string&)> on_warning_;
};

#endif  // RUNNER_SLOT_NOTIFICATION_H_
