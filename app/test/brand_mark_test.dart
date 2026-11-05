import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

Widget _app({bool reduced = false, bool animate = true}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Center(child: BrandMark(animate: animate)),
);

Finder get _image => find.descendant(of: find.byType(BrandMark), matching: find.byType(Image));

void main() {
  testWidgets('renders MegaWatt icon image asset with semantic label and animates in', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(_image, findsOneWidget);
    final image = tester.widget<Image>(_image);
    expect((image.image as AssetImage).assetName, 'assets/icon/icon.png');
    expect(image.semanticLabel, 'MegaWatt');

    // FadeTransition starts fading in
    final fadeFinder = find.descendant(of: find.byType(BrandMark), matching: find.byType(FadeTransition));
    expect(fadeFinder, findsOneWidget);

    await tester.pump(Motion.brand);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0, reason: 'no loop: the ticker is done');
  });

  testWidgets('with reduced motion the finished mark is there at once', (tester) async {
    await tester.pumpWidget(_app(reduced: true));

    expect(_image, findsOneWidget);
    final image = tester.widget<Image>(_image);
    expect((image.image as AssetImage).assetName, 'assets/icon/icon.png');
    expect(image.semanticLabel, 'MegaWatt');
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('with animate false the mark renders still without ticker', (tester) async {
    await tester.pumpWidget(_app(animate: false));

    expect(_image, findsOneWidget);
    final image = tester.widget<Image>(_image);
    expect((image.image as AssetImage).assetName, 'assets/icon/icon.png');
    expect(image.semanticLabel, 'MegaWatt');
    expect(tester.binding.transientCallbackCount, 0);
  });
}
