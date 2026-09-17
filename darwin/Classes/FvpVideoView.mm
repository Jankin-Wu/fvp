// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FvpVideoView+Internal.h"

#if TARGET_OS_OSX

#import "FvpDanmakuView.h"

#include "mdk/Player.h"
#include "mdk/RenderAPI.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <memory>

using namespace mdk;

/// Renderer that presents into a caller-owned `CAMetalLayer`.
///
/// Unlike `TexturePlayer` this never creates an offscreen target: mdk renders
/// straight into the layer's drawable. mdk owns the drawable lifecycle through
/// the layer, so we only hold the device/queue/layer pointers and the render
/// callback that asks the layer for its next drawable and renders one frame.
class LayerPlayer final : public Player
{
public:
    /// Serial queue the render blocks run on. Declared first so the inline
    /// members below can reference it. Per player, because the drawable it
    /// acquires belongs to this player's layer alone; both mdk's render
    /// callback and the view's layout path funnel through it.
    dispatch_queue_t renderQueue_ = dispatch_queue_create("fvp.render", DISPATCH_QUEUE_SERIAL);

    LayerPlayer(int64_t handle, CAMetalLayer* layer, int width, int height)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle)), layer_(layer)
    {
        device_ = MTLCreateSystemDefaultDevice();
        cmdQueue_ = [device_ newCommandQueue];

        MetalRenderAPI ra{};
        ra.device = (__bridge void*)device_;
        ra.cmdQueue = (__bridge void*)cmdQueue_;
        ra.layer = (__bridge void*)layer_;
        ra.colorFormat = (unsigned)layer_.pixelFormat;
        // mdk has to be able to obtain a drawable for each frame it renders.
        // This callback is how the renderer gets its render target: without it
        // mdk has nowhere to draw and the view stays black.
        ra.opaque = (void*)this;
        ra.currentRenderTarget = [](const void* opaque) -> const void* {
            LayerPlayer* p = (LayerPlayer*)opaque;
            // The same drawable is presented after renderVideo(), so it is
            // acquired here and handed to mdk as the render target.
            if (!p->pendingDrawable_) {
                p->pendingDrawable_ = [p->layer_ nextDrawable];
            }
            return p->pendingDrawable_
                ? (__bridge const void*)p->pendingDrawable_.texture : nullptr;
        };
        setRenderAPI(&ra);

        // ColorSpaceUnknown tells the renderer to follow the decoded frame's
        // own colorspace and send HDR10 metadata when the source carries it,
        // i.e. HDR sources enable HDR display and SDR sources stay SDR. This
        // is the only mode that keeps HDR on the wire; ColorSpaceBT709 (the
        // default) tone maps every HDR source down to SDR.
        set(ColorSpaceUnknown);

        // Foreign render-pass mode: mdk tells us when a frame is ready and we
        // render it into the drawable obtained by currentRenderTarget.
        // renderVideo() MUST NOT be called from inside the callback (mdk holds
        // its render mutex while invoking it), so it is scheduled instead.
        //
        // Register the callback BEFORE the surface size: setVideoSurfaceSize()
        // invokes the render callback to ask for a first frame, so doing it the
        // other way round drops that initial request and the renderer never
        // starts producing frames (renderVideo() then keeps returning -1).
        setRenderCallback([this](void*){
            scheduleRender();
        });

        setVideoSurfaceSize(width, height);
    }

    /// Stops the render callback and waits for any in-flight render block to
    /// finish, so the caller can safely destroy this player and its layer.
    ///
    /// Must be called while the view is still alive — mdk asserts if
    /// setRenderCallback runs during dealloc/autorelease-pool teardown, so the
    /// intended caller is FvpVideoView.dispose via the Dart-side
    /// releasePlatformView, never ~LayerPlayer.
    void stopRendering() {
        if (renderCallbackCleared_.exchange(true)) {
            return;
        }
        disposed_.store(true);
        setRenderCallback(nullptr);
        // Wait for an in-flight render block to finish before the caller
        // destroys the player. dispatch_sync on renderQueue_ is safe here: the
        // queue never dispatches back to the caller's thread, and the block
        // only touches the layer, which is still alive. Without this the player
        // could be destroyed while the block was inside renderVideo().
        dispatch_sync(renderQueue_, ^{});
    }

    ~LayerPlayer() override {
        // The view is expected to have called stopRendering() already. If it
        // did not, only flag disposal here — mdk asserts when setRenderCallback
        // runs during dealloc, and a destructor can be reached from
        // autorelease-pool teardown. Flagging makes any in-flight block bail
        // out instead of touching the layer.
        disposed_.store(true);
    }

    void setSurfaceSize(int width, int height) {
        setVideoSurfaceSize(width, height);
    }

private:
    void scheduleRender() {
        if (disposed_.load() || scheduled_.exchange(true)) {
            return;
        }
        // Render on a private serial queue rather than the main queue. The
        // drawable acquisition below blocks, and mdk holds its render mutex
        // across currentRenderTarget; doing that work on the main queue lets
        // the main thread block on a mutex the render callback owns, which
        // wedges the whole UI (worst during a quality switch, when the layout
        // pass also calls setSurfaceSize for this player).
        dispatch_async(renderQueue_, ^{
            this->scheduled_.store(false);
            if (this->disposed_.load()) {
                return;
            }
            @autoreleasepool {
                if (!this->pendingDrawable_) {
                    this->pendingDrawable_ = [this->layer_ nextDrawable];
                }
                this->renderVideo();
                [this->pendingDrawable_ present];
                this->pendingDrawable_ = nil;
            }
        });
    }

public:
    CAMetalLayer* layer_ = nil;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> cmdQueue_ = nil;
    id<CAMetalDrawable> pendingDrawable_ = nil;

private:
    std::atomic<bool> scheduled_{false};
    std::atomic<bool> disposed_{false};
    /// Set once setRenderCallback(nullptr) has run, so it is never called twice
    /// (mdk asserts on a second call during teardown).
    std::atomic<bool> renderCallbackCleared_{false};
};

@implementation FvpVideoView {
    CAMetalLayer* _metalLayer;
    std::shared_ptr<LayerPlayer> _player;
    int _videoWidth;
    int _videoHeight;
    BOOL _disposed;
    int64_t _playerHandle;
    /// Danmaku/subtitle overlay drawn above the video layer, created on demand
    /// when Dart first sends overlay content.
    FvpDanmakuView* _danmakuView;
    /// Set in -dealloc so dispose skips the mdk callback teardown, which
    /// asserts when called from a destructor.
    BOOL deallocating_;
}

/// The view currently owning each player's render target.
///
/// Each FvpVideoView builds its own LayerPlayer around the same mdk player
/// handle, and mdk drives whichever render callback was registered last. When
/// Flutter detaches and re-attaches the platform view during layout (which it
/// does on every rebuild of the surrounding subtree), the old view is not
/// destroyed before the new one appears, so without this registry every
/// re-attach leaves a LayerPlayer behind that keeps receiving render callbacks
/// and pushing empty frames over the live picture.
///
/// Guarded by a lock: views are created and disposed on both the main thread
/// and Flutter's platform thread, and a take-over mutates the map while the
/// outgoing view is still being torn down.
static NSMutableDictionary<NSNumber*, FvpVideoView*>* ActiveViewMap() {
    static NSMutableDictionary* map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSLock* ActiveViewLock() {
    static NSLock* lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

/// Claims this player's render target for [view], returning the view that held
/// it before (if any). The caller disposes the outgoing view outside the lock.
static FvpVideoView* TakeOverPlayerView(int64_t playerHandle, FvpVideoView* view) {
    [ActiveViewLock() lock];
    FvpVideoView* previous = ActiveViewMap()[@(playerHandle)];
    ActiveViewMap()[@(playerHandle)] = view;
    [ActiveViewLock() unlock];
    return previous;
}

/// Releases [view]'s claim, but only if it still holds it — a newer view that
/// took over must not be evicted by the outgoing view's teardown.
static void ReleasePlayerView(int64_t playerHandle, FvpVideoView* view) {
    [ActiveViewLock() lock];
    if (ActiveViewMap()[@(playerHandle)] == view) {
        [ActiveViewMap() removeObjectForKey:@(playerHandle)];
    }
    [ActiveViewLock() unlock];
}

/// Detaches the platform-view renderer bound to [playerHandle].
///
/// Called from the platform channel when Dart disposes the player. Doing the
/// detach here — rather than from the NSView lifecycle — keeps mdk's
/// setRenderCallback off the AppKit teardown path, where it asserts, and off
/// the compositor's per-frame remove/re-insert of platform views.
static void DetachPlayerView(int64_t playerHandle) {
    [ActiveViewLock() lock];
    FvpVideoView* view = ActiveViewMap()[@(playerHandle)];
    [ActiveViewMap() removeObjectForKey:@(playerHandle)];
    [ActiveViewLock() unlock];
    [view dispose];
}

+ (nullable mdk::Player*)playerHandle:(int64_t)playerHandle
{
    [ActiveViewLock() lock];
    FvpVideoView* view = ActiveViewMap()[@(playerHandle)];
    [ActiveViewLock() unlock];
    return [view player];
}

+ (nullable FvpVideoView*)activeViewForHandle:(int64_t)playerHandle
{
    [ActiveViewLock() lock];
    FvpVideoView* view = ActiveViewMap()[@(playerHandle)];
    [ActiveViewLock() unlock];
    return view;
}

- (instancetype)initWithFrame:(NSRect)frame
                   playerHandle:(int64_t)playerHandle
                          width:(int)width
                         height:(int)height
{
    self = [super initWithFrame:frame];
    if (self) {
        _videoWidth = width;
        _videoHeight = height;
        _disposed = NO;
        _playerHandle = playerHandle;

        // Hand the render target over from any view still bound to this player:
        // mdk keeps only the most recently registered render callback, so the
        // previous view's LayerPlayer would otherwise keep being driven against
        // a surface that is no longer on screen. The claim is taken under the
        // registry lock, but the outgoing view is disposed after releasing it —
        // its teardown touches the same registry.
        FvpVideoView* previous = TakeOverPlayerView(playerHandle, self);
        if (previous != nil && previous != self) {
            [previous dispose];
        }

        self.wantsLayer = YES;
        // A layer-backed NSView must not resize its own layer implicitly; this
        // view sizes the drawable explicitly from its bounds.
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

        _metalLayer = [CAMetalLayer layer];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        _metalLayer.device = device;
        _metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
        _metalLayer.framebufferOnly = NO;
        _metalLayer.opaque = YES;
        // Opt the layer into EDR so values outside [0,1] reach the compositor.
        // Without this the layer is treated as SDR and HDR highlights clip.
        _metalLayer.wantsExtendedDynamicRangeContent = YES;
        // ExtendedLinearDisplayP3 keeps unclamped values and lets the system
        // map them onto the display's actual gamut and headroom.
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
        if (cs) {
            _metalLayer.colorspace = cs;
            CGColorSpaceRelease(cs);
        }
        // Drawables are sized in device pixels; the view's contentsScale is
        // updated in viewDidChangeBackingProperties.
        _metalLayer.contentsScale = self.window.backingScaleFactor ?: 2.0;

        self.layer = _metalLayer;

        if (width > 0 && height > 0) {
            _metalLayer.drawableSize = CGSizeMake(width, height);
        }

        _player = std::make_shared<LayerPlayer>(playerHandle, _metalLayer, width, height);

    }
    return self;
}

- (void)layout {
    [super layout];
    [self updateDrawableSize];
}

/// The live player this view renders, for overlays that need a playback clock.
- (nullable mdk::Player*)player {
    return _player ? _player.get() : nullptr;
}

/// The overlay drawing danmaku and subtitles above the video layer, created on
/// first use.
///
/// The overlay is a subview rather than a sibling so it is carried along by
/// whatever the compositor does to this view, and it sits above the metal layer
/// by being added after `self.layer` is assigned.
- (nullable FvpDanmakuView*)danmakuView {
    return _danmakuView;
}

- (nullable FvpDanmakuView*)ensureDanmakuView {
    if (_danmakuView != nil) {
        return _danmakuView;
    }
    FvpDanmakuView* overlay = [[FvpDanmakuView alloc] initWithPlayerHandle:_playerHandle];
    if (overlay == nil) {
        return nil;
    }
    overlay.frame = self.bounds;
    [self addSubview:overlay];
    _danmakuView = overlay;
    return overlay;
}

+ (void)detachPlayerHandle:(int64_t)playerHandle {
    DetachPlayerView(playerHandle);
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    // Moving between displays can change both the scale factor and the EDR
    // capability; CAMetalLayer re-negotiates EDR headroom on the new display
    // as long as wantsExtendedDynamicRangeContent stays set.
    _metalLayer.contentsScale = self.window.backingScaleFactor ?: _metalLayer.contentsScale;
    [self updateDrawableSize];
}

- (void)updateDrawableSize {
    if (_disposed || !_player) {
        return;
    }
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) {
        return;
    }
    // Draw at video resolution so the renderer is not asked to scale; the
    // compositor scales the layer to the view's on-screen rect.
    CGFloat scale = _metalLayer.contentsScale;
    if (_videoWidth > 0 && _videoHeight > 0) {
        _metalLayer.drawableSize = CGSizeMake(_videoWidth, _videoHeight);
    } else {
        _metalLayer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    }
    _player->setSurfaceSize(_videoWidth > 0 ? _videoWidth : (int)size.width,
                            _videoHeight > 0 ? _videoHeight : (int)size.height);
}

- (BOOL)isOpaque {
    return YES;
}

- (void)dispose {
    if (_disposed) {
        return;
    }
    _disposed = YES;
    // Tear the overlay down before the player goes away: it reads the player's
    // playback clock every frame.
    [_danmakuView teardown];
    [_danmakuView removeFromSuperview];
    _danmakuView = nil;
    // Stop the renderer while this view is still a live object. The intended
    // path is the Dart side calling releasePlatformView on player disposal; a
    // view that is merely deallocated (never disposed) skips the mdk callback
    // teardown, because mdk asserts when setRenderCallback runs during dealloc.
    if (!deallocating_) {
        _player->stopRendering();
    }
    // Stop owning this player's render target, unless a newer view already
    // took it over (in which case that view is the live one).
    ReleasePlayerView(_playerHandle, self);
    _player.reset();
    _metalLayer = nil;
    self.layer = nil;
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
    [super viewWillMoveToWindow:newWindow];
    // Deliberately does NOT touch the renderer. Flutter's compositor removes
    // and re-inserts platform views on every frame it presents, so this fires
    // constantly during normal playback, and mdk asserts if setRenderCallback
    // runs from here. The renderer is detached explicitly when the Dart side
    // disposes the player view (see FvpVideoView.dispose), which is the one
    // point where the player is known to be going away for good.
}

- (void)dealloc {
    deallocating_ = YES;
    [self dispose];
}
@end

@implementation FvpVideoViewFactory

/// Flutter only decodes the Dart-side creation parameters when the factory
/// declares the codec they were encoded with. Without this the factory is
/// handed nil arguments and every field reads back as 0.
- (NSObject<FlutterMessageCodec>*)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

- (NSView*)createWithViewIdentifier:(int64_t)viewId
                     arguments:(id _Nullable)args
{
    NSDictionary* params = (NSDictionary*)args;
    const auto handle = ((NSNumber*)params[@"player"]).longLongValue;
    const auto width = ((NSNumber*)params[@"width"]).intValue;
    const auto height = ((NSNumber*)params[@"height"]).intValue;
    auto view = [[FvpVideoView alloc] initWithFrame:NSZeroRect
                                       playerHandle:handle
                                              width:width
                                             height:height];
    return view;
}
@end

#endif // TARGET_OS_OSX
