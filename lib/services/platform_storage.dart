import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Per-platform storage behaviour that has no cross-platform plugin.
///
/// Today that is exactly one thing: keeping the app's large, re-downloadable
/// files out of iCloud backup.
///
/// Android needs nothing here. `android:allowBackup="false"` in the manifest
/// switches backup off for the whole app, so every method on this class is a
/// no-op there. iOS has no equivalent switch: everything the app writes under
/// its Documents directory is backed up to iCloud by default, and this app
/// writes a ~500 MB language model, an optional 175 MB encoder, a copy of the
/// Markdown corpus and a SQLite index into it. All four are either downloadable
/// again or rebuildable from the bundled assets, so backing them up burns a
/// user's iCloud quota for nothing — and Apple's review guidelines single that
/// pattern out.
///
/// Storing them in `Library/Caches` instead, which is never backed up, would
/// trade one problem for a worse one: iOS purges Caches under disk pressure,
/// and an offline safety app that loses its model on the day it is needed has
/// failed at its only job. Documents plus the exclusion flag is the combination
/// Apple actually recommends.
class PlatformStorage {
  /// Must match `AppDelegate.storageChannelName` in ios/Runner/AppDelegate.swift.
  static const channelName = 'com.surviveai.survive_ai/platform_storage';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// Whether this platform needs per-file backup exclusion at all.
  ///
  /// Kept as a getter rather than inlined at every call site so the tests —
  /// and the parity test in particular — have one symbol to point at.
  static bool get needsBackupExclusion => !kIsWeb && Platform.isIOS;

  /// Mark [path] as excluded from iCloud and iTunes backup.
  ///
  /// Returns true when the flag was set, false when there was nothing to do
  /// (not iOS, or the path does not exist yet). Never throws: failing to set a
  /// backup flag must not be able to take down a model download, so a platform
  /// error is logged and swallowed.
  ///
  /// Safe to call repeatedly. On a directory the flag is inherited by files
  /// created inside it afterwards, so the cheapest place to call this is right
  /// after the directory is created and before it is filled.
  static Future<bool> excludeFromBackup(String path) async {
    if (!needsBackupExclusion) return false;
    try {
      final excluded = await _channel.invokeMethod<bool>('excludeFromBackup', {
        'path': path,
      });
      return excluded ?? false;
    } on MissingPluginException {
      // The channel is registered by the iOS AppDelegate. A test harness or a
      // platform without it should behave exactly like Android: do nothing.
      return false;
    } on PlatformException catch (e) {
      debugPrint('Could not exclude $path from backup: ${e.message}');
      return false;
    }
  }
}
