#ifndef RUNNER_SLOT_NOTIFICATION_POLICY_H_
#define RUNNER_SLOT_NOTIFICATION_POLICY_H_

#include <algorithm>
#include <cstdint>
#include <string>

inline bool ShouldShowSlotNotification(bool enabled, bool main_visible, int64_t id) {
  return enabled && !main_visible && id > 0;
}

class SlotNotificationLifetime {
 public:
  static constexpr uint32_t kDurationMs = 2000;
  void Restart(uint64_t now) { deadline_ = now + kDurationMs; active_ = true; }
  void Dismiss() { active_ = false; }
  void SetDragging(bool dragging) { dragging_ = dragging; }
  bool ShouldHide(uint64_t now) const { return active_ && !dragging_ && Remaining(now) == 0; }
  uint32_t Remaining(uint64_t now) const {
    return active_ && now < deadline_ ? static_cast<uint32_t>(deadline_ - now) : 0;
  }
 private:
  bool active_ = false;
  bool dragging_ = false;
  uint64_t deadline_ = 0;
};

inline std::wstring SlotNotificationText(int64_t id, std::wstring name) {
  for (auto& c : name) if (c < L' ') c = L' ';
  const auto first = name.find_first_not_of(L' ');
  if (first == std::wstring::npos) return std::to_wstring(id);
  name = name.substr(first, name.find_last_not_of(L' ') - first + 1);
  constexpr size_t kMaxNameUnits = 1024;
  if (name.size() > kMaxNameUnits) {
    name.resize(kMaxNameUnits);
    if (name.back() >= 0xd800 && name.back() <= 0xdbff) name.pop_back();
    name += L'\u2026';
  }
  return std::to_wstring(id) + L" \u2014 " + name;
}

struct SlotNotificationPoint { int64_t x; int64_t y; };
struct SlotNotificationArea { int64_t left; int64_t top; int64_t right; int64_t bottom; };

inline SlotNotificationPoint ClampSlotNotification(
    SlotNotificationArea work, int width, int height, SlotNotificationPoint position) {
  return {std::clamp(position.x, work.left, (std::max)(work.left, work.right - width)),
          std::clamp(position.y, work.top, (std::max)(work.top, work.bottom - height))};
}

inline SlotNotificationPoint DefaultSlotNotificationPosition(
    SlotNotificationArea work, int width, int height, int margin) {
  return ClampSlotNotification(work, width, height,
      {work.left + (work.right - work.left - width) / 2, work.bottom - height - margin});
}

#endif  // RUNNER_SLOT_NOTIFICATION_POLICY_H_
