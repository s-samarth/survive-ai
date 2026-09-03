import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/download_service.dart';

/// Every argument these tests reject arrives from `manifest.json`, which is
/// fetched from a remote host. The app trusts that file enough to write its
/// contents to disk and hand them to an inference engine, so the boundary is
/// where the trust has to stop.
void main() {
  const downloads = DownloadService();

  group('DownloadService rejects unsafe paths', () {
    // `path.join` does not interpret `..`. It happily builds a path that
    // escapes the app's documents directory, so a manifest naming
    // `../../databases/survive_ai.db` could overwrite the corpus with
    // downloaded content — no error, no symptom until retrieval breaks.
    for (final name in [
      '../escape.bin',
      '../../databases/survive_ai.db',
      'nested/path.bin',
      r'windows\path.bin',
      '/absolute.bin',
      '.hidden',
      '',
      '   ',
    ]) {
      test('filename ${name.isEmpty ? '<empty>' : name}', () {
        expect(
          () => downloads.download(
            url: 'https://example.com/f.bin',
            filename: name,
            subfolder: 'models',
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    }

    test('subfolder is checked too', () {
      expect(
        () => downloads.download(
          url: 'https://example.com/f.bin',
          filename: 'model.bin',
          subfolder: '../..',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DownloadService requires https', () {
    // minSdk is 24 and Android only blocks cleartext by default from API 28,
    // so on the oldest supported devices an http URL in the manifest would be
    // fetched in the clear — and the response becomes model weights. The
    // SHA-256 check does not help: the manifest carrying the hash arrives over
    // the same channel.
    for (final url in [
      'http://example.com/model.bin',
      'ftp://example.com/model.bin',
      'file:///etc/passwd',
      'not a url at all',
      '',
    ]) {
      test('rejects ${url.isEmpty ? '<empty>' : url}', () {
        expect(
          () => downloads.download(
            url: url,
            filename: 'model.bin',
            subfolder: 'models',
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    }
  });
}
