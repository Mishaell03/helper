#ifndef RUNNER_SLOT_NOTIFICATION_SURFACE_H_
#define RUNNER_SLOT_NOTIFICATION_SURFACE_H_

#include <windows.h>

// Give the layered HWND an actual surface BEFORE requesting display affinity.
// It must contain only alpha-zero pixels: protection is not established yet.
// This does not show the HWND, draw text, or use SetLayeredWindowAttributes
// (which would interfere with subsequent UpdateLayeredWindow calls).
inline bool InitializeSlotNotificationSurface(HWND window, DWORD* error) {
  *error = ERROR_SUCCESS;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = 1;
  info.bmiHeader.biHeight = -1;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!bitmap) {
    *error = GetLastError();
    return false;
  }
  *static_cast<DWORD*>(pixels) = 0;
  HDC dc = CreateCompatibleDC(nullptr);
  if (!dc) {
    *error = GetLastError();
    DeleteObject(bitmap);
    return false;
  }
  HGDIOBJ previous = SelectObject(dc, bitmap);
  bool result = false;
  if (!previous || previous == HGDI_ERROR) {
    *error = GetLastError();
  } else {
    SIZE size{1, 1};
    POINT source{};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    result = UpdateLayeredWindow(window, nullptr, nullptr, &size, dc, &source,
                                 0, &blend, ULW_ALPHA) != FALSE;
    if (!result) *error = GetLastError();
    SelectObject(dc, previous);
  }
  DeleteDC(dc);
  DeleteObject(bitmap);
  return result;
}

#endif  // RUNNER_SLOT_NOTIFICATION_SURFACE_H_
