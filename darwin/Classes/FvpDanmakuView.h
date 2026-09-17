// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// macOS only. The header and implementation are shared with the iOS pod via
// the darwin/ symlink, so guard the declarations: AppKit and CATextLayer are
// unavailable on iOS.
#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import <Cocoa/Cocoa.h>

/// Overlay that draws danmaku (bullet comments) and a subtitle line stack on
/// top of the video, for the platform-view render path.
///
/// `FvpVideoView` presents video through an on-screen `CAMetalLayer`, which
/// composites above every Flutter layer — so the Flutter-rendered danmaku and
/// subtitle widgets are invisible in that mode. This view is mounted as a
/// subview of `FvpVideoView`, above the metal layer, and draws those overlays
/// itself.
///
/// Each live comment owns one `CATextLayer`; the per-frame work is only
/// repositioning those layers, which the render server composites on the GPU.
///
/// The view owns its own playback clock: it polls the mdk player's
/// `position()` every frame rather than taking a position pushed from Dart,
/// because Dart's ticker is far coarser than a frame and a seek would be
/// reflected one tick late.
@interface FvpDanmakuView : NSView

/// Attaches the overlay to [playerHandle]'s live player for its clock.
- (nullable instancetype)initWithPlayerHandle:(int64_t)playerHandle;

/// Replaces the whole comment list and restarts the timeline at the current
/// playback position. Each entry is a dictionary with:
/// `time` (ms, NSNumber), `text` (NSString), `color` (ARGB, NSNumber),
/// `type` (NSNumber: 0 scroll, 1 top, 2 bottom).
- (void)setDanmakuList:(NSArray<NSDictionary*>* _Nonnull)list;

/// Applies rendering options. `fontSize` is in points, `area` and `opacity`
/// are 0...1, `durationMs` is how long a comment takes to cross the screen and
/// `staticDurationMs` how long a top/bottom comment stays.
- (void)setOptions:(NSDictionary* _Nonnull)options;

/// Freezes the comments in place. The overlay keeps polling but stops
/// advancing time, so resuming does not jump.
- (void)pauseDanmaku;

/// Resumes advancing time.
- (void)resumeDanmaku;

/// Removes every comment currently on screen and rewinds the timeline to the
/// current playback position.
- (void)clearDanmaku;

/// Hides or shows the whole overlay without dropping the comment list.
- (void)setDanmakuVisible:(BOOL)visible;

/// Sets the subtitle lines drawn at the bottom of the video area. An empty
/// array hides them.
///
/// [bottomPadding] is in points, measured from the bottom edge of the view —
/// the caller resolves the user's vertical-position setting against the text
/// height, so the same estimate is not duplicated here.
- (void)setSubtitleLines:(NSArray<NSString*>* _Nonnull)lines
                fontSize:(CGFloat)fontSize
           bottomPadding:(CGFloat)bottomPadding
                 opacity:(CGFloat)opacity;

/// Stops the clock and releases every layer. Safe to call more than once.
- (void)teardown;

@end

#endif // TARGET_OS_OSX