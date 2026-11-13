import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/dashboard/views/home_screen.dart';

void main() {
  testWidgets('home greets the user and opens the library and profile', (
    tester,
  ) async {
    String? category;
    var libraryOpened = false;
    var profileOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          loadProfile: () async => {'full_name': 'Liau'},
          onProfile: () async {
            profileOpened = true;
          },
          onLibrary: (value) async {
            category = value;
            libraryOpened = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome back, Liau'), findsOneWidget);
    await tester.tap(find.text('Explore the library'));
    await tester.pumpAndSettle();
    expect(libraryOpened, isTrue);
    expect(category, isNull);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(profileOpened, isTrue);
  });

  testWidgets('home remains usable if profile request fails', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          loadProfile: () async => throw Exception('offline'),
          onProfile: () async {},
          onLibrary: (_) async {
            opened = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home fits a small phone with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: HomeScreen(
          loadProfile: () async => {'full_name': 'Liau'},
          onProfile: () async {},
          onLibrary: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
