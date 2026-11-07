import 'package:flutter/foundation.dart';

bool get isWindows =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
