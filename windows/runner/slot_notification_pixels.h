#ifndef RUNNER_SLOT_NOTIFICATION_PIXELS_H_
#define RUNNER_SLOT_NOTIFICATION_PIXELS_H_

#include <cstdint>
#include <cstddef>
#include <vector>

struct SlotPixelSpan { int left; int top; int right; int bottom; };

// A real HWND region, not HTTRANSPARENT (which only forwards within a thread),
// lets other processes receive clicks through every alpha-zero background pixel.
inline std::vector<SlotPixelSpan> SlotNotificationSpans(
    const std::vector<uint32_t>& pixels, int width, int height) {
  std::vector<SlotPixelSpan> spans;
  if (width <= 0 || height <= 0 ||
      static_cast<uint64_t>(width) * height != pixels.size()) return spans;
  for (int y = 0; y < height; ++y) {
    int x = 0;
    while (x < width) {
      if ((pixels[static_cast<std::size_t>(y) * width + x] >> 24) == 0) { ++x; continue; }
      const int left = x++;
      while (x < width && (pixels[static_cast<std::size_t>(y) * width + x] >> 24) != 0) ++x;
      spans.push_back({left, y, x, y + 1});
    }
  }
  return spans;
}

#endif  // RUNNER_SLOT_NOTIFICATION_PIXELS_H_
