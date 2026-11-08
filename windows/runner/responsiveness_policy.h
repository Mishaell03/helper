#ifndef RUNNER_RESPONSIVENESS_POLICY_H_
#define RUNNER_RESPONSIVENESS_POLICY_H_

#include <cstdint>

inline bool ResponsivenessTimedOut(uint64_t now, uint64_t native_beat,
    uint64_t dart_beat, bool armed, bool visible) {
  constexpr uint64_t kTimeoutMs = 6000;
  return armed && visible &&
      ((now >= native_beat && now - native_beat > kTimeoutMs) ||
       (now >= dart_beat && now - dart_beat > kTimeoutMs));
}

#endif  // RUNNER_RESPONSIVENESS_POLICY_H_
