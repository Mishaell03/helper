#ifndef RUNNER_AUTO_HIDE_POLICY_H_
#define RUNNER_AUTO_HIDE_POLICY_H_

#include <cstdint>

struct AutoHideOption {
  bool enabled = true;
  uint32_t seconds = 10;
  bool operator==(const AutoHideOption& other) const {
    return enabled == other.enabled && seconds == other.seconds;
  }
};

inline bool ValidAutoHideSeconds(uint32_t seconds) {
  return seconds >= 10 && seconds <= 60 && seconds % 5 == 0;
}

// Two independent configurations, but only one active view/deadline. All times
// come from the UI thread's monotonic clock; no polling or worker is needed.
class AutoHidePolicy {
 public:
  AutoHideOption normal;
  AutoHideOption viewer{true, 30};

  void Context(uint64_t now, bool visible, bool viewer_open, bool suspended) {
    if (visible_ == visible && viewer_open_ == viewer_open && suspended_ == suspended) return;
    visible_ = visible;
    viewer_open_ = viewer_open;
    suspended_ = suspended;
    Activity(now);
  }
  void Configure(uint64_t now, AutoHideOption main, AutoHideOption text) {
    normal = main;
    viewer = text;
    Activity(now);
  }
  void Activity(uint64_t now) {
    const auto option = viewer_open_ ? viewer : normal;
    active_ = visible_ && !suspended_ && option.enabled;
    deadline_ = active_ ? now + option.seconds * 1000ULL : 0;
  }
  uint32_t Remaining(uint64_t now) const {
    return active_ && now < deadline_ ? static_cast<uint32_t>(deadline_ - now) : 0;
  }
  bool expired(uint64_t now) const { return active_ && now >= deadline_; }

 private:
  bool visible_ = false;
  bool viewer_open_ = false;
  bool suspended_ = true;
  bool active_ = false;
  uint64_t deadline_ = 0;
};

#endif  // RUNNER_AUTO_HIDE_POLICY_H_
