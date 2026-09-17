// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// macOS only. Private to the plugin: never include this from a header that
// ends up in the pod's public headers.
//
// `FvpVideoView.h` is in the framework umbrella header, which Swift imports, so
// it must stay free of C++ — mdk's headers include the C++ standard library and
// cannot be scanned into a Clang module. The parts of `FvpVideoView` that are
// typed in terms of `mdk::Player` live here instead.
#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import "FvpVideoView.h"

#include "mdk/Player.h"

@interface FvpVideoView (Internal)

/// The live `mdk::Player` behind `playerHandle`, or null when no view currently
/// owns it.
///
/// The returned pointer belongs to the registry, not to the caller: it is valid
/// only while the view that registered it is alive, so callers must not retain
/// it past the operation they need it for. Used by the danmaku overlay to read
/// the playback clock the renderer is driving.
+ (nullable mdk::Player*)playerHandle:(int64_t)playerHandle;

@end

#endif // TARGET_OS_OSX