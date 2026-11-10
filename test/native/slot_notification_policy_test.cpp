#include "../../windows/runner/slot_notification_policy.h"

#include <cassert>
#include <limits>

int main() {
  assert(SlotNotificationText(42, L"") == L"42");
  assert(SlotNotificationText(3, L"  Блок 😀\n ") == L"3 — Блок 😀");
  assert(SlotNotificationText(9, L"\t\n") == L"9");
  std::wstring long_name(1100, L'я');
  assert(SlotNotificationText(1, long_name).back() == L'…');
  assert(SlotNotificationText(1, long_name).size() < 1100);
  std::wstring surrogate_name(1023, L'a');
  surrogate_name += static_cast<wchar_t>(0xd83d);
  surrogate_name += static_cast<wchar_t>(0xde00);
  assert(SlotNotificationText(1, surrogate_name).find(static_cast<wchar_t>(0xd83d)) == std::wstring::npos);

  for (bool enabled : {false, true}) {
    for (bool visible : {false, true}) {
      assert(ShouldShowSlotNotification(enabled, visible, 42) == (enabled && !visible));
      assert(!ShouldShowSlotNotification(enabled, visible, 0));
    }
  }
  SlotNotificationLifetime lifetime;
  assert(lifetime.Remaining(0) == 0);
  lifetime.Restart(100);
  assert(lifetime.Remaining(100) == 3000);
  assert(lifetime.Remaining(3099) == 1);
  assert(lifetime.Remaining(3100) == 0);
  lifetime.Restart(3000);
  assert(lifetime.Remaining(3100) == 2900); // Old queued timer cannot dismiss new text.
  assert(lifetime.Remaining(6000) == 0);
  lifetime.Restart(7000);
  lifetime.Dismiss(); // Show main window / disable / teardown.
  assert(lifetime.Remaining(7000) == 0);

  const SlotNotificationArea primary{0, 0, 1920, 1040};
  auto p = DefaultSlotNotificationPosition(primary, 200, 30, 24);
  assert(p.x == 860 && p.y == 986);
  p = ClampSlotNotification(primary, 200, 30, {-500, 90000});
  assert(p.x == 0 && p.y == 1010);
  p = ClampSlotNotification({-1920, -100, 0, 940}, 200, 30, {-1800, 900});
  assert(p.x == -1800 && p.y == 900);
  p = ClampSlotNotification(primary, 200, 30,
      {std::numeric_limits<int64_t>::max(), std::numeric_limits<int64_t>::max()});
  assert(p.x == 1720 && p.y == 1010);
  p = ClampSlotNotification({0, 0, 10, 10}, 200, 30, {50, 50});
  assert(p.x == 0 && p.y == 0);
}
