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

  // Dart configures the frameless style; BackgroundManager owns DWM alpha and
  // the final presentation. Do not show a decorated/unprotected window here.

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
  if (flutter_controller_ &&
      ((message == WM_SHOWWINDOW && wparam != FALSE) ||
       message == WM_DWMCOMPOSITIONCHANGED)) {
    // A hidden Flutter swapchain may not have presented recently. Request a
    // fresh frame on reveal/compositor reset instead of reusing stale pixels.
    flutter_controller_->ForceRedraw();
  }
  // Keep the real system cursor as an arrow on resize borders and during the
  // native move/size loop. Capture exclusion does not hide cursor-shape changes
  // from OBS. Flutter border MouseRegions also request the ordinary arrow.
  if (message == WM_ENTERSIZEMOVE) {
    in_move_size_loop_ = true;
    SetCursor(LoadCursor(nullptr, IDC_ARROW));
  } else if (message == WM_EXITSIZEMOVE) {
    in_move_size_loop_ = false;
    SetCursor(LoadCursor(nullptr, IDC_ARROW));
  } else if (message == WM_SIZING) {
    SetCursor(LoadCursor(nullptr, IDC_ARROW));
  } else if (message == WM_SETCURSOR) {
    const int hit_test = static_cast<int>(LOWORD(lparam));
    if (in_move_size_loop_ ||
        (hit_test >= HTLEFT && hit_test <= HTBOTTOMRIGHT)) {
      SetCursor(LoadCursor(nullptr, IDC_ARROW));
      return TRUE;
    }
  }

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
