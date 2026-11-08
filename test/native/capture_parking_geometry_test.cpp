#include "../../windows/runner/capture_parking_geometry.h"

#include <cassert>
#include <iostream>

int main() {
  for (const auto desktop : {
      CaptureParkingPosition{0, 0}, CaptureParkingPosition{-1920, 0},
      CaptureParkingPosition{-3840, -2160}}) {
    const auto parked = CaptureParkingPositionFor(desktop.x, desktop.y, 7680, 1600);
    assert(parked.x >= desktop.x + 7680);
    assert(parked.y == desktop.y);
  }
  const auto limit = CaptureParkingPositionFor(2147483000, 0, 640, 368);
  assert(static_cast<int64_t>(limit.x) + 368 < 2147483000);
  std::cout << "PASS: capture parking outside single/multi-monitor and negative-coordinate desktops\n";
}
