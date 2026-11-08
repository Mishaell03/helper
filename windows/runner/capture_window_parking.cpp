#include "capture_window_parking.h"

#include <algorithm>

#include "capture_parking_geometry.h"

namespace {
CaptureParkingPosition ParkingPosition(HWND window) {
  RECT rectangle{};
  GetWindowRect(window, &rectangle);
  return CaptureParkingPositionFor(GetSystemMetrics(SM_XVIRTUALSCREEN),
      GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN),
      rectangle.right - rectangle.left);
}
}  // namespace

bool CaptureWindowParking::Park(HWND window) {
  if (parked_) return true;
  if (!IsWindowVisible(window) || IsIconic(window) || !GetWindowRect(window, &restore_)) return false;
  const auto position = ParkingPosition(window);
  parked_ = true;
  if (!SetWindowPos(window, nullptr, position.x, position.y, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
    parked_ = false;
    return false;
  }
  return true;
}

bool CaptureWindowParking::Restore(HWND window) {
  if (!parked_) return true;
  // The monitor used before hiding may have been unplugged meanwhile.
  if (!MonitorFromRect(&restore_, MONITOR_DEFAULTTONULL)) {
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (GetMonitorInfoW(MonitorFromRect(&restore_, MONITOR_DEFAULTTONEAREST), &info)) {
      const LONG width = (std::min)(restore_.right - restore_.left, info.rcWork.right - info.rcWork.left);
      const LONG height = (std::min)(restore_.bottom - restore_.top, info.rcWork.bottom - info.rcWork.top);
      restore_ = {info.rcWork.left, info.rcWork.top,
                  info.rcWork.left + width, info.rcWork.top + height};
    }
  }
  parked_ = false;  // Allow the restore position through WM_WINDOWPOSCHANGING.
  if (!SetWindowPos(window, nullptr, restore_.left, restore_.top,
      restore_.right - restore_.left, restore_.bottom - restore_.top,
      SWP_NOZORDER | SWP_NOACTIVATE)) {
    parked_ = true;
    return false;
  }
  return true;
}

void CaptureWindowParking::ConstrainPosition(WINDOWPOS* position) const {
  if (!parked_) return;
  const auto parked = ParkingPosition(position->hwnd);
  position->x = parked.x;
  position->y = parked.y;
  position->flags &= ~static_cast<UINT>(SWP_NOMOVE | SWP_SHOWWINDOW);
  position->flags |= SWP_NOACTIVATE;
}

void CaptureWindowParking::Repark(HWND window) const {
  if (!parked_) return;
  const auto position = ParkingPosition(window);
  SetWindowPos(window, nullptr, position.x, position.y, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}
