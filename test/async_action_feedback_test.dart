import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachidesk_sorayomi/src/widgets/async_buttons/async_checkbox_list_tile.dart';
import 'package:tachidesk_sorayomi/src/widgets/async_buttons/async_icon_button.dart';
import 'package:tachidesk_sorayomi/src/widgets/async_buttons/async_list_tile.dart';
import 'package:tachidesk_sorayomi/src/widgets/async_buttons/async_text_button.dart';
import 'package:tachidesk_sorayomi/src/widgets/custom_circular_progress_indicator.dart';

void main() {
  testWidgets('AsyncIconButton blocks duplicate in-flight taps',
      (tester) async {
    final completer = Completer<void>();
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncIconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              calls++;
              return completer.future;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    await tester.tap(find.byType(IconButton));
    expect(calls, 1);
    expect(find.byType(MiniCircularProgressIndicator), findsOneWidget);

    completer.complete();
    await tester.pump();
    expect(find.byIcon(Icons.delete), findsOneWidget);
  });

  testWidgets('AsyncCheckboxListTile rolls back a failed mutation',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncCheckboxListTile(
            value: false,
            title: const Text('Category'),
            onChanged: (_) async => false,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
  });

  testWidgets('AsyncTextButton blocks duplicate in-flight taps',
      (tester) async {
    final completer = Completer<void>();
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncTextButton(
            onPressed: () {
              calls++;
              return completer.future;
            },
            child: const Text('Save'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.tap(find.byType(TextButton));
    expect(calls, 1);
    completer.complete();
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('AsyncListTile blocks duplicate in-flight taps', (tester) async {
    final completer = Completer<void>();
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListTile(
            title: const Text('Run'),
            onTap: (_) {
              calls++;
              return completer.future;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pump();
    await tester.tap(find.text('Run'));
    expect(calls, 1);
    completer.complete();
    await tester.pump();
    expect(find.text('Run'), findsOneWidget);
  });
}
