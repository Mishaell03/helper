#include "../../windows/runner/slot_notification_pixels.h"
#include "../../windows/runner/slot_notification_policy.h"

#include <cassert>

int main() {
  assert(!SlotNotificationCaptureSupported(0));
  assert(!SlotNotificationCaptureSupported(19040));
  assert(SlotNotificationCaptureSupported(19041));
  assert(SlotNotificationCaptureSupported(19045));
  assert(SlotNotificationCaptureSupported(22000));
  assert(SlotNotificationProtectionConfirmed(true, true, 0x11, 0, false));
  assert(SlotNotificationProtectionConfirmed(true, true, 0x11, 8, false)); // Stale last-error after success is irrelevant.
  assert(SlotNotificationProtectionConfirmed(true, false, 0, 87, false));
  assert(SlotNotificationProtectionConfirmed(true, false, 0, 50, false));
  assert(!SlotNotificationProtectionConfirmed(false, false, 0, 87, false));
  assert(!SlotNotificationProtectionConfirmed(false, true, 0x11, 0, false));
  assert(!SlotNotificationProtectionConfirmed(true, true, 0, 0, false));
  assert(!SlotNotificationProtectionConfirmed(true, true, 1, 0, false));
  assert(!SlotNotificationProtectionConfirmed(true, false, 0, 8, false));
  assert(!SlotNotificationProtectionConfirmed(true, false, 0, 87, true));
  assert(SlotNotificationSpans({}, 0, 0).empty());
  assert(SlotNotificationSpans({0}, -1, 1).empty());
  assert(SlotNotificationSpans({0}, 2, 1).empty());
  assert(SlotNotificationSpans(std::vector<uint32_t>(12, 0), 4, 3).empty());
  // RGB != 0 does not make an alpha-zero pixel clickable. Partial alpha does.
  const std::vector<uint32_t> pixels{
    0x00ffffff, 0xffffffff, 0x10101010, 0,
    0xffffffff, 0, 0, 0x01000000,
    0, 0, 0, 0,
  };
  const auto spans = SlotNotificationSpans(pixels, 4, 3);
  assert(spans.size() == 3);
  assert(spans[0].left == 1 && spans[0].right == 3 && spans[0].top == 0 && spans[0].bottom == 1);
  assert(spans[1].left == 0 && spans[1].right == 1 && spans[1].top == 1 && spans[1].bottom == 2);
  assert(spans[2].left == 3 && spans[2].right == 4 && spans[2].top == 1 && spans[2].bottom == 2);
}
