// The walkthrough clip line of release notes: the poster is the one picture
// the app fetches from notes, so only the two files of that very release pass.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/models/release_info.dart';

const _v = '0.1.20';
const _base = '$appRepositoryUrl/releases/download/v$_v';

String _line({String poster = '$_base/$_v-whats-new.jpg', String video = '$_base/$_v-whats-new.mp4'}) =>
    "[![Watch what's new · 6 changes · 0:19 · 7.5 MB]($poster)]($video)";

void main() {
  test('finds the clip of this release and leaves the notes without its line', () {
    final notes = '${_line()}\n\n### Pages\n\nA page opens.';
    final clip = ReleaseClip.find(notes, _v)!;
    expect(clip.label, "Watch what's new · 6 changes · 0:19 · 7.5 MB");
    expect(clip.poster, '$_base/$_v-whats-new.jpg');
    expect(clip.video, '$_base/$_v-whats-new.mp4');
    expect(clip.without(notes), '### Pages\n\nA page opens.');
  });

  test('refuses a poster or a clip from anywhere else', () {
    const other = '$appRepositoryUrl/releases/download/v0.1.19';
    for (final (poster, video) in [
      ('https://evil.example/$_v-whats-new.jpg', '$_base/$_v-whats-new.mp4'),
      ('$_base/$_v-whats-new.jpg', 'https://evil.example/$_v-whats-new.mp4'),
      ('$other/0.1.19-whats-new.jpg', '$other/0.1.19-whats-new.mp4'),
      ('$_base/other.jpg', '$_base/$_v-whats-new.mp4'),
      (
        'https://github.com:8443/$appRepository/releases/download/v$_v/$_v-whats-new.jpg',
        '$_base/$_v-whats-new.mp4',
      ),
      ('$_base/$_v-whats-new.jpg?x=1', '$_base/$_v-whats-new.mp4'),
      ('http://github.com/$appRepository/releases/download/v$_v/$_v-whats-new.jpg', '$_base/$_v-whats-new.mp4'),
    ]) {
      expect(
        ReleaseClip.find(_line(poster: poster, video: video), _v),
        isNull,
        reason: '$poster $video',
      );
    }
  });

  test('a clip mentioned inside a sentence is not the clip line', () {
    expect(ReleaseClip.find('See ${_line()} for more.', _v), isNull);
  });
}
