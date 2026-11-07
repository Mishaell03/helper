#ifndef RUNNER_STARTUP_VISIBILITY_H_
#define RUNNER_STARTUP_VISIBILITY_H_

// Only explicit user actions or the first normal launch may reveal the window.
// A late first-frame callback must never undo the user's Show/Hide hotkey.
class StartupVisibility {
 public:
  explicit StartupVisibility(bool start_hidden) : start_hidden_(start_hidden) {}

  bool FinishStartup() {
    if (finished_) return false;
    finished_ = true;
    if (start_hidden_ || user_requested_) return false;
    may_show_ = true;
    return true;
  }

  void Reveal() { user_requested_ = true; may_show_ = true; }
  void Hide() { user_requested_ = true; may_show_ = false; }
  bool may_show() const { return may_show_; }

 private:
  const bool start_hidden_;
  bool finished_ = false;
  bool user_requested_ = false;
  bool may_show_ = false;
};

#endif  // RUNNER_STARTUP_VISIBILITY_H_
