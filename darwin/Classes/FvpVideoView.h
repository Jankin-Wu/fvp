// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// macOS only. The header and implementation are shared with the iOS pod via
// the darwin/ symlink, so guard the declarations: Cocoa/AppKit and the
// CAMetalLayer renderer are unavailable on iOS.
#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>

@class FvpDanmakuView;

/// Platform view presenting video through its own `CAMetalLayer` instead of a
/// Flutter texture.
///
/// The texture path renders into a fixed 8-bit `MTLPixelFormatBGRA8Unorm`
/// surface, which caps the output at SDR. This view instead hands mdk an
/// on-screen `CAMetalLayer` and lets mdk drive presentation itself, which is
/// the only configuration where mdk enables HDR display: `Player.set(
/// ColorSpaceUnknown)` forwards HDR10 metadata to the display and switches the
/// layer between SDR and HDR transfer functions to match the decoded frame.
/// See the `MetalRenderAPI.layer` notes in mdk's `RenderAPI.h`.
///
/// Because the video becomes a real view in the AppKit hierarchy it composites
/// above Flutter's own layers, so Flutter widgets stacked over the video area
/// (danmaku, JS-style subtitle overlays) are not visible here. Callers that
/// need those overlays must render them natively instead — mdk draws embedded
/// and externally loaded subtitle tracks into this layer itself.
@interface FvpVideoView : NSView

- (_Nullable instancetype)initWithFrame:(NSRect)frame
                           playerHandle:(int64_t)playerHandle
                                  width:(int)width
                                 height:(int)height;

/// Detaches the renderer and releases the native player wrapper.
- (void)dispose;

/// Detaches whichever view currently owns `playerHandle`'s render target.
///
/// Called from the platform channel when Dart disposes the player. The detach
/// cannot live in the NSView lifecycle: Flutter's compositor removes and
/// re-inserts platform views on every presented frame, and mdk asserts if its
/// render callback is changed from that path.
+ (void)detachPlayerHandle:(int64_t)playerHandle;

/// The view currently rendering `playerHandle`'s output, or nil.
///
/// Used by the platform channel to reach the overlay of whichever view is live;
/// the returned view must only be touched on the main thread.
+ (nullable FvpVideoView*)activeViewForHandle:(int64_t)playerHandle;

/// The danmaku/subtitle overlay mounted on this view, or nil when none has been
/// created yet.
@property (nullable, nonatomic, readonly) FvpDanmakuView* danmakuView;

/// Returns the overlay, creating and mounting it on the first call.
///
/// The overlay must be a subview of this view to composite above the metal
/// layer, and it is created lazily so playback without danmaku pays nothing.
/// Main thread only.
- (nullable FvpDanmakuView*)ensureDanmakuView;

@end

/// Creates `FvpVideoView`s for the `fvp/video-view` platform view type.
@interface FvpVideoViewFactory : NSObject<FlutterPlatformViewFactory>
@end

#endif // TARGET_OS_OSX
