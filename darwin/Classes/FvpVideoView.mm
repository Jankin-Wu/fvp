// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FvpVideoView.h"

#if TARGET_OS_OSX

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

        setVideoSurfaceSize(width, height);

        // Foreign render-pass mode: mdk tells us when a frame is ready and we
        // render it into the drawable obtained by currentRenderTarget.
        // renderVideo() MUST NOT be called from inside the callback (mdk holds
        // its render mutex while invoking it), so it is scheduled instead.
        setRenderCallback([this](void*){
            scheduleRender();
        });
    }

    ~LayerPlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
        disposed_.store(true);
    }

    void setSurfaceSize(int width, int height) {
        setVideoSurfaceSize(width, height);
        scheduleRender();
    }

private:
    void scheduleRender() {
        if (disposed_.load() || scheduled_.exchange(true)) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            this->scheduled_.store(false);
            if (this->disposed_.load()) {
                return;
            }
            @autoreleasepool {
                if (!this->pendingDrawable_) {
                    this->pendingDrawable_ = [this->layer_ nextDrawable];
                }
                double ts = this->renderVideo();
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
};

@implementation FvpVideoView {
    CAMetalLayer* _metalLayer;
    std::shared_ptr<LayerPlayer> _player;
    int _videoWidth;
    int _videoHeight;
    BOOL _disposed;
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
    // Tear the renderer down before the layer goes away: mdk holds a raw
    // pointer to it, and its destructor stops the render callback.
    _player.reset();
    _metalLayer = nil;
    self.layer = nil;
}

- (void)dealloc {
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
