import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/features/millitop_ai/mavae_catalog_service.dart';

void main() {
  test('extracts real-world availability question', () {
    expect(
      mavaeTitleQuery('Is Halloween H20 available to watch?'),
      'Halloween H20',
    );
    expect(mavaeTitleQuery('Can I watch Interstellar?'), 'Interstellar');
  });
  test('general questions are not classified as title lookup', () {
    expect(mavaeTitleQuery('Which of those is most lighthearted?'), isNull);
  });
  test('matches title words without confusing 20 with 200', () {
    expect(
      mavaeMatchesTitle(
        'Halloween H20: 20 Years Later (1998)',
        'Halloween H20',
      ),
      isTrue,
    );
    expect(mavaeMatchesTitle('Halloween H200', 'Halloween H20'), isFalse);
    expect(mavaeMatchesTitle('The Matrix Reloaded', 'Matrix'), isTrue);
  });
}
