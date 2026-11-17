import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helper/migration/migration_controller.dart';
import 'package:helper/migration/migration_panel.dart';

void main() {
  testWidgets('Generated SQL has a library action without a JSON input', (
    tester,
  ) async {
    final controller = MigrationController(
      engineDirectory: Directory('unused'),
      settingsFile: File('unused.json'),
    );
    controller.excel = File('normalized.xlsx');
    controller.sql = File('migration.sql');
    final imports = <String>[];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MigrationPanel(
            controller: controller,
            onImportSql: (filename) async => imports.add(filename),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Добавить SQL в библиотеку'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Добавить SQL в библиотеку')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить SQL в библиотеку'));
    await tester.pumpAndSettle();
    expect(imports, ['migration.sql']);
    expect(find.text('SQL уже в библиотеке'), findsOneWidget);
    expect(find.textContaining('JSON'), findsNothing);
    final button = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('SQL уже в библиотеке'),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'SQL source switches without removing Excel input or losing SQL',
    (tester) async {
      final controller = MigrationController(
        engineDirectory: Directory('unused'),
        settingsFile: File('unused.json'),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MigrationPanel(controller: controller)),
        ),
      );
      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      final excel = field('Путь к папке с .xlsx');
      final ddl = field('SQL Server: CREATE TABLE …');
      await tester.enterText(excel, 'C:\\Excel');
      await tester.enterText(ddl, 'CREATE TABLE A (Id INT);');
      await tester.tap(find.byType(DropdownButtonFormField<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Файл или папка SQL').last);
      await tester.pumpAndSettle();
      expect(excel, findsOneWidget);
      expect(field('Путь к файлу .sql или папке'), findsOneWidget);
      expect(ddl, findsNothing);
      expect(tester.widget<TextField>(excel).controller!.text, 'C:\\Excel');
      await tester.tap(find.byType(DropdownButtonFormField<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ввести SQL').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(ddl).controller!.text,
        'CREATE TABLE A (Id INT);',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
