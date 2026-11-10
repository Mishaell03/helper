#include "../../windows/runner/auto_hide_policy.h"

#include <cassert>

int main() {
  AutoHidePolicy policy;
  assert(policy.normal.enabled && policy.normal.seconds == 10);
  assert(policy.viewer.enabled && policy.viewer.seconds == 30);
  for (uint32_t seconds = 0; seconds <= 70; ++seconds) {
    assert(ValidAutoHideSeconds(seconds) ==
        (seconds >= 10 && seconds <= 60 && seconds % 5 == 0));
  }
  policy.Context(0, true, false, false);
  assert(policy.Remaining(0) == 10000);
  assert(!policy.expired(9999));
  assert(policy.expired(10000));
  policy.Activity(9000);
  assert(!policy.expired(10000)); // An outdated queued timer.
  assert(policy.expired(19000));
  policy.Context(10000, true, true, false);
  assert(policy.Remaining(10000) == 30000);
  assert(!policy.expired(19000)); // Normal timer no longer applies.
  policy.Context(20000, true, true, false); // Rebuild/identical context isn't activity.
  assert(policy.Remaining(20000) == 20000);
  policy.Context(21000, true, false, false);
  assert(policy.Remaining(21000) == 10000);
  policy.Context(22000, false, false, false);
  assert(!policy.expired(99000));
  policy.Activity(99000); // Hidden slot changes must not start a window timer.
  assert(policy.Remaining(99000) == 0);
  policy.Context(100000, true, false, false);
  assert(policy.Remaining(100000) == 10000);
  assert(!policy.expired(100001));
  policy.Context(109999, true, false, true); // Recording/modal/drag/file dialog/reset.
  assert(!policy.expired(999999));
  policy.Activity(999999);
  assert(policy.Remaining(999999) == 0);
  policy.Context(1000000, true, false, false);
  assert(policy.Remaining(1000000) == 10000);
  policy.Configure(1000000, {false, 10}, {true, 45});
  assert(policy.Remaining(1000000) == 0);
  assert(!policy.expired(9999999));
  policy.Context(1000001, true, true, false);
  assert(policy.Remaining(1000001) == 45000);
  policy.Configure(1000002, {true, 60}, {false, 45});
  assert(policy.Remaining(1000002) == 0);
  policy.Context(1000003, true, false, false);
  assert(policy.Remaining(1000003) == 60000);
  policy.Configure(1000003, {false, 60}, {false, 45});
  assert(!policy.expired(9999999));
  policy.Context(1000003, true, true, false);
  assert(!policy.expired(9999999));
  policy.Context(1000004, false, false, true); // Teardown.
  assert(!policy.expired(9999999));
}
