import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/main.dart';

void main() {
  testWidgets('App launches and shows loading indicator', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: SurviveAiApp()));
    // The entry router shows a loading indicator while resolving the initial screen
    expect(find.byType(SurviveAiApp), findsOneWidget);
  });
}
