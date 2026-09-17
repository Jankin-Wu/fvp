/*
 * Copyright (c) 2023 WangBin <wbsecg1 at gmail.com>
 */
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'fvp_method_channel.dart';

abstract class FvpPlatform extends PlatformInterface {
  /// Constructs a FvpPlatform.
  FvpPlatform() : super(token: _token);

  static final Object _token = Object();

  static FvpPlatform _instance = MethodChannelFvp();

  /// The default instance of [FvpPlatform] to use.
  ///
  /// Defaults to [MethodChannelFvp].
  static FvpPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FvpPlatform] when
  /// they register themselves.
  static set instance(FvpPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<int> createTexture(
      int playerHandle, int width, int height, bool tunnel) {
    throw UnimplementedError('createTexture() has not been implemented.');
  }

  Future<void> releaseTexture(int playerHandle, int textureId) {
    throw UnimplementedError('releaseTexture() has not been implemented.');
  }

  /// Detaches the platform-view renderer bound to [playerHandle].
  ///
  /// Called when the player is disposed. No-op on platforms without a
  /// platform-view renderer.
  Future<void> releasePlatformView(int playerHandle) async {}

  /// Deletes the native player API object (`mdkPlayerAPI**` at [ppAddress],
  /// ownership transferred) on a detached native thread. Returns true when
  /// the platform took over the deletion; false when the caller must delete
  /// it by other means.
  ///
  /// `mdkPlayerAPI_delete` can deadlock when a player is destroyed while a
  /// seek or reader job is still in flight. Running it on a detached native
  /// thread lets a hung deletion leak the thread instead of blocking process
  /// exit, which is what happens when the deletion runs on a Dart isolate:
  /// VM shutdown waits for every isolate of the group to terminate.
  Future<bool> deletePlayerAsync(int ppAddress) async => false;

  Future<void> setMixWithOthers(bool mixWithOthers) async {
    throw UnimplementedError('setMixWithOthers() has not been implemented.');
  }
}
