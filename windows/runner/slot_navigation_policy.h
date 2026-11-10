#ifndef RUNNER_SLOT_NAVIGATION_POLICY_H_
#define RUNNER_SLOT_NAVIGATION_POLICY_H_

// Visibility is the runner's logical visibility, not HWND foreground status or
// IsWindowVisible alone (Windows 10 can park a logically hidden window).
class SlotNavigationPolicy {
 public:
  bool enabled(bool visible, bool inserting) const {
    return !inserting && (mode_ == Mode::enabled ||
                          (mode_ == Mode::automatic && visible));
  }
  void Show(bool inserting) {
    mode_ = inserting ? Mode::disabled : Mode::automatic;
  }
  void Hide() { mode_ = Mode::automatic; }
  void Disable() { mode_ = Mode::disabled; }
  void Toggle(bool visible, bool inserting) {
    mode_ = enabled(visible, inserting) || inserting ? Mode::disabled : Mode::enabled;
  }

 private:
  enum class Mode { automatic, enabled, disabled };
  Mode mode_ = Mode::automatic;
};

#endif  // RUNNER_SLOT_NAVIGATION_POLICY_H_
