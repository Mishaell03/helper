#ifndef RUNNER_CAPTURE_PARKING_GEOMETRY_H_
#define RUNNER_CAPTURE_PARKING_GEOMETRY_H_

#include <cstdint>
#include <limits>

struct CaptureParkingPosition { int x; int y; };

inline CaptureParkingPosition CaptureParkingPositionFor(
    int left, int top, int desktop_width, int window_width) {
  const int64_t right = static_cast<int64_t>(left) + desktop_width + 64;
  if (right <= (std::numeric_limits<int>::max)()) {
    return {static_cast<int>(right), top};
  }
  const int64_t outside_left = static_cast<int64_t>(left) - window_width - 64;
  return {static_cast<int>(outside_left), top};
}

#endif  // RUNNER_CAPTURE_PARKING_GEOMETRY_H_
