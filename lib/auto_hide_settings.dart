class AutoHideOption {
  const AutoHideOption({this.enabled = true, required this.seconds});

  static const durations = [10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60];
  final bool enabled;
  final int seconds;

  static AutoHideOption fromMap(Object? value, int defaultSeconds) {
    if (value is! Map ||
        value['enabled'] is! bool ||
        !durations.contains(value['seconds'])) {
      return AutoHideOption(seconds: defaultSeconds);
    }
    return AutoHideOption(
      enabled: value['enabled'] as bool,
      seconds: value['seconds'] as int,
    );
  }

  Map<String, Object> toMap() => {'enabled': enabled, 'seconds': seconds};
  AutoHideOption copyWith({bool? enabled, int? seconds}) => AutoHideOption(
    enabled: enabled ?? this.enabled,
    seconds: seconds ?? this.seconds,
  );
}
