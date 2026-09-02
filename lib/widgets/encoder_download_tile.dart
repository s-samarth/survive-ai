import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/embedding/encoder_download.dart';

/// Offers the optional query encoder, and says plainly what it buys.
///
/// The app works without it. Framing this as a missing requirement would be
/// wrong and would push someone to spend 175 MB of a metered connection under
/// the impression that the app is broken until they do. It is an upgrade:
/// better search, especially for questions phrased in words the guides do not
/// use, on top of a keyword search that already works offline.
///
/// It is deliberately not offered during first-run setup. The generator is
/// already a ~500 MB download standing between a person and an app they may
/// need today, and stacking a second one there trades an emergency answer for
/// a better emergency answer.
class EncoderDownloadTile extends ConsumerStatefulWidget {
  const EncoderDownloadTile({super.key});

  @override
  ConsumerState<EncoderDownloadTile> createState() =>
      _EncoderDownloadTileState();
}

class _EncoderDownloadTileState extends ConsumerState<EncoderDownloadTile> {
  double? _progress;
  String? _message;

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _message = null;
    });

    final files = await ref.read(encoderFilesProvider.future);
    final ok = await const EncoderDownload().fetch(
      files,
      onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      },
    );
    if (!mounted) return;

    setState(() {
      _progress = null;
      _message = ok
          ? 'Smarter search is on.'
          : 'Download did not finish. It resumes where it stopped — '
                'try again on a stronger connection.';
    });
    if (ok) {
      // Rebuild the encoder so the dense leg joins without a restart.
      ref.invalidate(embedderLoaderProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(encoderInstalledProvider);
    final active = ref.watch(embeddingServiceProvider).isEnabled;
    final downloading = _progress != null;

    if (installed.valueOrNull == true) {
      return ListTile(
        leading: Icon(
          Icons.travel_explore,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: const Text('Smarter search'),
        subtitle: Text(
          active
              ? 'On. Finds the right guide even when your words differ from it.'
              : 'Installed — starting up.',
        ),
      );
    }

    final megabytes =
        EncoderDownload.totalBytes(
          ref.watch(encoderFilesProvider).valueOrNull ?? EncoderDownload.fallback,
        ) ~/
        (1024 * 1024);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.travel_explore_outlined),
          title: const Text('Smarter search (optional)'),
          subtitle: Text(
            'Search already works offline. This adds understanding of what '
            'you meant, not just the words you typed — it is the difference '
            'between "chakkar aa rahe hain" reaching the heatstroke guide and '
            'missing it. $megabytes MB, one time, over Wi-Fi.',
          ),
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text(
                  '${((_progress ?? 0) * 100).toStringAsFixed(0)}% — you can '
                  'keep using the app, and this resumes if it is interrupted.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _download,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _message!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
