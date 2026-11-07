import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/updates/app_updater.dart';
import 'package:helper/updates/update_settings.dart';

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.body);
  @override
  final int statusCode;
  final String body;
  @override
  final HttpHeaders headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final HttpClientResponse response;
  @override
  bool followRedirects = true;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.response);
  final HttpClientResponse response;
  final urls = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return _Request(response);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UiUpdater extends AppUpdater {
  int checks = 0;
  int preparations = 0;
  bool updateAvailable = false;
  @override
  Future<String> currentVersion() async => '1.0.0';
  @override
  Future<AppRelease?> check(String current) async {
    checks++;
    return updateAvailable
        ? AppRelease('v1.1.0', Uri.https('github.com', '/'), 100, '')
        : null;
  }

  @override
  Future<void> prepare(
    AppRelease release,
    void Function(double) progress,
  ) async {
    preparations++;
  }

  @override
  Future<void> launchInstaller() async {}
  @override
  Future<void> cleanup() async {}
}

void main() {
  Map<String, dynamic> release({String tag = 'v1.1.0', String? digest}) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'assets': [
      {
        'name': AppRelease.assetName,
        'browser_download_url':
            'https://github.com/Mishaell03/helper/releases/download/$tag/${AppRelease.assetName}',
        'size': 123,
        'digest': digest ?? 'sha256:${'a' * 64}',
      },
    ],
  };

  test('Numeric versions, equal/older releases and build metadata', () {
    expect(
      ReleaseVersion.parse('v1.10.0').compareTo(ReleaseVersion.parse('1.9.9')),
      greaterThan(0),
    );
    expect(AppRelease.newer(release(tag: 'v1.0.0'), '1.0.0+99'), isNull);
    expect(AppRelease.newer(release(tag: 'v0.9.0'), '1.0.0'), isNull);
    expect(AppRelease.newer(release(), '1.0.0')!.tag, 'v1.1.0');
    expect(
      AppRelease.newer({...release(), 'prerelease': true}, '1.0.0'),
      isNull,
    );
    expect(() => ReleaseVersion.parse('main'), throwsFormatException);
  });

  test(
    'Reject missing ZIP, missing digest, foreign URLs and excessive size',
    () {
      expect(
        () => AppRelease.newer({...release(), 'assets': []}, '1.0.0'),
        throwsFormatException,
      );
      expect(
        () => AppRelease.newer(release(digest: ''), '1.0.0'),
        throwsFormatException,
      );
      for (final override in [
        {'browser_download_url': 'https://example.com/update.zip'},
        {'size': AppUpdater.maxArchiveBytes + 1},
      ]) {
        final data = release();
        (data['assets'] as List)[0].addAll(override);
        expect(() => AppRelease.newer(data, '1.0.0'), throwsFormatException);
      }
    },
  );

  test(
    'No HTTP until explicit check; correct repo, errors and client cleanup',
    () async {
      for (final status in [200, 404, 403]) {
        final client = _Client(_Response(status, jsonEncode(release())));
        var creations = 0;
        final updater = AppUpdater(
          clientFactory: () {
            creations++;
            return client;
          },
        );
        expect(creations, 0);
        if (status == 200) {
          expect((await updater.check('1.0.0'))!.tag, 'v1.1.0');
        } else {
          await expectLater(updater.check('1.0.0'), throwsFormatException);
        }
        expect(client.urls.single, AppUpdater.latestUri);
        expect(client.closed, isTrue);
      }
    },
  );

  testWidgets('Manual button only, current version and declined install', (
    tester,
  ) async {
    final updater = _UiUpdater();
    var installs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateSettings(
            enabled: true,
            updater: updater,
            install: (launch) async {
              installs++;
              await launch();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(updater.checks, 0);
    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
    expect(updater.checks, 1);
    expect(find.textContaining('Установлена последняя версия'), findsOneWidget);
    updater.updateAvailable = true;
    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
    expect(find.text('Доступна версия v1.1.0'), findsOneWidget);
    await tester.tap(find.text('Позже'));
    await tester.pumpAndSettle();
    expect(updater.preparations, 0);
    expect(installs, 0);
    await tester.tap(find.text('Проверить обновления'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();
    expect(updater.preparations, 1);
    expect(installs, 1);
  });
}
