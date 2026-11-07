#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "capture_exclusion.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Apply to the top-level HWND before it can be shown. Supported capture APIs
  // omit this window on Windows 10 2004+; older Windows may show a black area.
  ExcludeFromCapture(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  background_manager_ = std::make_unique<BackgroundManager>(
      GetHandle(), flutter_controller_->engine()->messenger(), start_hidden_);

  // Dart configures transparency, the frameless style and always-on-top before
  // window_manager shows the window. Do not show a decorated window here.

  // Request the initial frame while Dart prepares the window for display.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  background_manager_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                               LPARAM const lparam) noexcept {
  // Handle close before plugins: X/Alt+F4 must hide, not destroy the engine.
  if (background_manager_ &&
      background_manager_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
