#ifndef RUNNER_SLOT_NOTIFICATION_SURFACE_H_
#define RUNNER_SLOT_NOTIFICATION_SURFACE_H_

#include <windows.h>
#include <dwmapi.h>
#include <cstring>
#include <utility>
#include <vector>

#include "slot_notification_pixels.h"
#include "window_composition.h"

struct SlotSurfaceError {
  const char* operation = "none";
  DWORD win32 = ERROR_SUCCESS;
  HRESULT hresult = S_OK;
  int graphics_status = -1;
  std::string detail;
  bool Win32(const char* api, DWORD code) {
    operation = api; win32 = code; hresult = S_OK; graphics_status = -1; detail.clear(); return false;
  }
  bool HResult(const char* api, HRESULT code) {
    operation = api; win32 = ERROR_SUCCESS; hresult = code; graphics_status = -1; detail.clear(); return false;
  }
  bool Graphics(const char* api, int code) {
    operation = api; win32 = ERROR_SUCCESS; hresult = S_OK; graphics_status = code; detail.clear(); return false;
  }
};

// Standard DWM-redirected top-level window. Deliberately NOT WS_EX_LAYERED,
// WS_EX_NOREDIRECTIONBITMAP or UpdateLayeredWindow: display affinity must protect
// the same ordinary redirected surface to which WM_PAINT presents the pixels.
// Premultiplied BGRA is copied unchanged, following Microsoft's text-on-glass
// DIB/BitBlt path. No theme/color-key/whole-window-opacity fallback is used.
class SlotNotificationSurface {
 public:
  SlotNotificationSurface() = default;
  ~SlotNotificationSurface() { Reset(); }
  SlotNotificationSurface(const SlotNotificationSurface&) = delete;
  SlotNotificationSurface& operator=(const SlotNotificationSurface&) = delete;

  static constexpr DWORD kExStyle = WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;

  static bool Configure(HWND window, SlotSurfaceError* error) {
    // Exactly the main window's configuration, including NC rendering policy
    // and ordering. Keep a single owner of this contract, not a near-copy.
    std::string detail;
    if (ConfigureTransparentComposition(window, &detail)) return true;
    error->HResult("ConfigureTransparentComposition", E_FAIL);
    error->detail = std::move(detail); // Preserve the helper's actual API/HRESULT.
    return false;
  }

  bool SetFrame(HWND window, const std::vector<uint32_t>& pixels,
                int width, int height, int x, int y, SlotSurfaceError* error) {
    if (width <= 0 || height <= 0 || static_cast<uint64_t>(width) * height != pixels.size())
      return error->HResult("ValidateFrame", E_INVALIDARG);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    SlotNotificationSurface frame; // Own partial allocations on every exit, including exceptions.
    SetLastError(ERROR_SUCCESS);
    frame.bitmap_ = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!frame.bitmap_) return error->Win32("CreateDIBSection", GetLastError());
    std::memcpy(bits, pixels.data(), pixels.size() * sizeof(uint32_t));
    SetLastError(ERROR_SUCCESS);
    frame.dc_ = CreateCompatibleDC(nullptr);
    if (!frame.dc_) return error->Win32("CreateCompatibleDC", GetLastError());
    SetLastError(ERROR_SUCCESS);
    HGDIOBJ previous = SelectObject(frame.dc_, frame.bitmap_);
    if (!previous || previous == HGDI_ERROR) {
      const DWORD code = GetLastError();
      return error->Win32("SelectObject", code);
    }
    frame.previous_ = previous;
    frame.width_ = width;
    frame.height_ = height;
    const auto spans = SlotNotificationSpans(pixels, width, height);
    HRGN shape = nullptr;
    DWORD region_error = ERROR_SUCCESS;
    SetLastError(ERROR_SUCCESS);
    if (spans.empty()) {
      shape = CreateRectRgn(0, 0, 0, 0);
      if (!shape) region_error = GetLastError();
    }
    else {
      const size_t bytes = sizeof(RGNDATAHEADER) + spans.size() * sizeof(RECT);
      if (bytes > MAXDWORD) {
        return error->HResult("ValidateRegionSize", E_INVALIDARG);
      }
      std::vector<DWORD> data((bytes + sizeof(DWORD) - 1) / sizeof(DWORD));
      RGNDATAHEADER header{};
      header.dwSize = sizeof(header);
      header.iType = RDH_RECTANGLES;
      header.nCount = static_cast<DWORD>(spans.size());
      header.nRgnSize = static_cast<DWORD>(spans.size() * sizeof(RECT));
      header.rcBound = {width, height, 0, 0};
      auto* rectangles = reinterpret_cast<BYTE*>(data.data()) + sizeof(header);
      for (size_t i = 0; i < spans.size(); ++i) {
        const auto& span = spans[i];
        const RECT rectangle{span.left, span.top, span.right, span.bottom};
        std::memcpy(rectangles + i * sizeof(RECT), &rectangle, sizeof(rectangle));
        if (span.left < header.rcBound.left) header.rcBound.left = span.left;
        if (span.top < header.rcBound.top) header.rcBound.top = span.top;
        if (span.right > header.rcBound.right) header.rcBound.right = span.right;
        if (span.bottom > header.rcBound.bottom) header.rcBound.bottom = span.bottom;
      }
      std::memcpy(data.data(), &header, sizeof(header));
      SetLastError(ERROR_SUCCESS);
      shape = ExtCreateRegion(nullptr, static_cast<DWORD>(bytes),
                              reinterpret_cast<const RGNDATA*>(data.data()));
      if (!shape) region_error = GetLastError();
    }
    if (!shape) {
      return error->Win32(spans.empty() ? "CreateRectRgn(shape)" : "ExtCreateRegion", region_error);
    }
    // Synchronous WM_PAINT during geometry changes must see the new frame.
    // The candidate now owns the old frame and releases it on return.
    std::swap(bitmap_, frame.bitmap_);
    std::swap(dc_, frame.dc_);
    std::swap(previous_, frame.previous_);
    std::swap(width_, frame.width_);
    std::swap(height_, frame.height_);
    if (!SetWindowPos(window, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE)) {
      const DWORD code = GetLastError();
      DeleteObject(shape);
      return error->Win32("SetWindowPos", code);
    }
    if (!SetWindowRgn(window, shape, FALSE)) {
      const DWORD code = GetLastError();
      DeleteObject(shape); // On success the OS owns it; on failure we do.
      return error->Win32("SetWindowRgn", code);
    }
    if (!InvalidateRect(window, nullptr, FALSE)) return error->Win32("InvalidateRect", GetLastError());
    return true;
  }

  bool Paint(HDC target, SlotSurfaceError* error) const {
    if (!dc_) return true; // A new, hidden HWND never paints private content.
    SetLastError(ERROR_SUCCESS);
    if (!BitBlt(target, 0, 0, width_, height_, dc_, 0, 0, SRCCOPY))
      return error->Win32("BitBlt", GetLastError());
    return true;
  }

  bool empty() const { return dc_ == nullptr; }

  void Reset() {
    if (dc_) {
      if (previous_) SelectObject(dc_, previous_);
      DeleteDC(dc_);
    }
    if (bitmap_) DeleteObject(bitmap_);
    dc_ = nullptr; bitmap_ = nullptr; previous_ = nullptr;
    width_ = height_ = 0;
  }

 private:
  HDC dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ previous_ = nullptr;
  int width_ = 0;
  int height_ = 0;
};

#endif  // RUNNER_SLOT_NOTIFICATION_SURFACE_H_
