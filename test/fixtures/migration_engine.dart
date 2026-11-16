// Fake external process for testing the Flutter integration, not the generator.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.first;
  String option(String name) => args[args.indexOf(name) + 1];
  final format = option('--output-format');
  final output = option('--output-dir');
  stderr.write('diagnostic ' * 30000);
  stdout.writeln(jsonEncode({'event': 'progress', 'stage': 'validating'}));
  if (mode == 'wait') {
    await Future<void>.delayed(const Duration(minutes: 1));
  }
  if (mode == 'fail-sql' && format == 'sql-simple') {
    stdout.writeln(
      jsonEncode({'event': 'error', 'message': 'Invalid mapping'}),
    );
    exitCode = 2;
    return;
  }
  final name = format == 'sql-simple' ? 'migration.sql' : 'Normalized.xlsx';
  final file = File('$output${Platform.pathSeparator}$name');
  await file.writeAsString('test result');
  if (mode == 'no-completed') return;
  stdout.writeln(
    jsonEncode({
      'event': 'completed',
      'success': true,
      'output_file': mode == 'outside'
          ? File('$output/../outside.xlsx').absolute.path
          : file.absolute.path,
      'records': 1,
    }),
  );
}
