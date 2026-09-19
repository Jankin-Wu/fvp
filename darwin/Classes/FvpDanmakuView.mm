// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FvpDanmakuView.h"

#if TARGET_OS_OSX

#import "FvpVideoView+Internal.h"
// CATextLayer and its animations live here; AppKit only forward-declares them.
#import <QuartzCore/QuartzCore.h>
#include "mdk/Player.h"

/// Dispatch window, in milliseconds: comments whose start time is at most this
/// far behind the playback position are shown; anything earlier is skipped, so
/// a fresh view does not dump a burst of stale comments onto the screen.
/// Mirrors `_dispatchLookBehindMs` on the Flutter side.
static const int64_t kLookBehindMs = 500;

/// A position change larger than either threshold is a seek rather than normal
/// playback, and restarts the timeline. Mirrors `_backwardJumpThresholdMs` and
/// `_forwardJumpThresholdMs`.
static const int64_t kBackwardJumpThresholdMs = 200;
static const int64_t kForwardJumpThresholdMs = 3000;

/// Line height multiplier for the track height. Mirrors the `lineHeight: 1.6`
/// the Flutter renderer is configured with.
static const CGFloat kLineHeight = 1.6;

/// Stroke width in points. `NSAttributedString`'s `.strokeWidth` is expressed
/// as a percentage of the font size, unlike Flutter's point-based
/// `strokeWidth: 1.5`, so it is converted using the current font size.
static const CGFloat kDanmakuStrokeWidthPoints = 1.5;
static const CGFloat kSubtitleStrokeWidthPoints = 0.8;

/// Gap between stacked subtitle lines, in points.
static const CGFloat kSubtitleLineGap = 2.0;

/// Danmaku modes as sent from Dart.
typedef NS_ENUM(NSInteger, FvpDanmakuType) {
    FvpDanmakuTypeScroll = 0,
    FvpDanmakuTypeTop = 1,
    FvpDanmakuTypeBottom = 2,
};

/// How a comment travels across the screen.
typedef NS_ENUM(NSInteger, FvpDanmakuMotion) {
    /// Leftward across the view.
    FvpDanmakuMotionScroll,
    /// Parked at the top.
    FvpDanmakuMotionTop,
    /// Parked at the bottom.
    FvpDanmakuMotionBottom,
};

/// One comment, on screen or not yet dispatched.
@interface FvpDanmakuItem : NSObject
/// Start time in milliseconds, from the comment list.
@property(nonatomic) int64_t startMs;
@property(nonatomic, copy) NSString* text;
@property(nonatomic) uint32_t argb;
@property(nonatomic, strong) NSColor* color;
@property(nonatomic) FvpDanmakuMotion motion;
/// Track the comment occupies, or -1 while it is not on screen.
@property(nonatomic) NSInteger track;
/// Left edge of the comment's box, in the overlay's coordinate space.
@property(nonatomic) CGFloat frameX;
/// Distance from the top edge of the view to the top of the comment's box.
///
/// Measured as an offset from the top edge that the box extends *down* from, so
/// a scrolling or top comment on track `i` sets `(i + 1) * trackHeight` and
/// keeps its own height inside that band. A bottom comment instead hangs its
/// box *up* from the band it is on and sets `viewHeight - i * trackHeight`,
/// placing its bottom edge there. Measuring both from the top edge — rather than
/// from the bottom, which would move a comment when the view resizes — is what
/// lets [placeLayer:forItem:] be a single subtraction.
@property(nonatomic) CGFloat frameTopY;
/// Width of the drawn text, cached because track allocation reads it before
/// the layer exists.
@property(nonatomic) CGFloat width;
@property(nonatomic) CGFloat height;
@property(nonatomic, strong, nullable) CATextLayer* layer;
@end

@implementation FvpDanmakuItem
- (instancetype)init
{
    self = [super init];
    if (self) {
        _track = -1;
    }
    return self;
}
@end

@implementation FvpDanmakuView {
    // Whole comment list, sorted by start time.
    NSArray<FvpDanmakuItem*>* _items;
    int64_t* _startTimesMs;
    NSUInteger _itemCount;
    /// Index of the next comment to dispatch; the list is walked once, in order.
    NSUInteger _nextIndex;
    int64_t _lastPositionMs;
    BOOL _hasLastPosition;

    // Comments currently on screen.
    NSMutableArray<FvpDanmakuItem*>* _live;
    /// Per track, the time in milliseconds until which it stays claimed, or
    /// `NSNull` while it is free. Combines the two ways a track is held: a
    /// scrolling comment claims it only until it clears the right edge, a
    /// top/bottom comment for its whole display time.
    NSMutableArray* _trackReservedUntil;

    // Rendering options, all computed on the Dart side.
    CGFloat _fontSize;
    CGFloat _area;
    CGFloat _opacity;
    int64_t _durationMs;
    int64_t _staticDurationMs;
    NSString* _fontName;

    CATextLayer* _overlayLayer;
    NSMutableArray<CATextLayer*>* _subtitleLayers;
    /// Distance in points from the bottom edge to the subtitle block.
    CGFloat _subtitleBottomPadding;

    // Playback clock.
    int64_t _playerHandle;
    NSTimer* _clock;
    BOOL _running;
    BOOL _visible;
    BOOL _torndown;
    /// Playback position the overlay is currently showing, in milliseconds.
    int64_t _positionMs;
}

- (nullable instancetype)initWithPlayerHandle:(int64_t)playerHandle
{
    self = [super initWithFrame:NSZeroRect];
    if (!self) {
        return nil;
    }
    _playerHandle = playerHandle;
    [self commonInit];
    return self;
}

- (void)commonInit
{
    _items = @[];
    _live = [NSMutableArray array];
    _trackReservedUntil = [NSMutableArray array];
    _subtitleLayers = [NSMutableArray array];
    _fontSize = 20.0;
    _area = 1.0;
    _opacity = 1.0;
    _durationMs = 10000;
    _staticDurationMs = 5000;
    _fontName = @"PingFang SC";
    _running = NO;
    _visible = YES;
    _hasLastPosition = NO;
    _positionMs = 0;

    self.wantsLayer = YES;
    // Matches FvpVideoView: a layer-backed view must not let AppKit implicitly
    // animate layer changes, which turns positioning into a visible slide.
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _overlayLayer = [CATextLayer layer];
    _overlayLayer.frame = self.bounds;
    _overlayLayer.masksToBounds = YES;
    // Applies the user's opacity to every comment at once, the way the Flutter
    // renderer wraps its whole stack in a single Opacity widget.
    _overlayLayer.opacity = (float)_opacity;
    _overlayLayer.contentsScale = self.window.backingScaleFactor ?: 2.0;
    [self.layer addSublayer:_overlayLayer];

    [self startClockIfNeeded];
}

- (BOOL)isOpaque
{
    return NO;
}

/// Reads `Player::position()` through the registry.
///
/// The player is looked up on every read rather than cached: the view that owns
/// a given handle is replaced whenever the compositor re-attaches the platform
/// view, and a cached pointer would then be clocking the overlay against a
/// player that is no longer presenting.
- (int64_t)positionMs
{
    mdk::Player* player = [FvpVideoView playerHandle:_playerHandle];
    return player != nullptr ? player->position() : _positionMs;
}

- (mdk::PlaybackState)playbackState
{
    mdk::Player* player = [FvpVideoView playerHandle:_playerHandle];
    return player != nullptr ? player->state() : mdk::PlaybackState::Stopped;
}

#pragma mark - Layout

- (void)layout
{
    [super layout];
    _overlayLayer.frame = self.bounds;
    // Track geometry depends on the view height, so a resize re-places every
    // live comment on its track.
    [self relayoutLiveItems];
    [self layoutSubtitleLayers];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    CGFloat scale = self.window.backingScaleFactor ?: _overlayLayer.contentsScale;
    _overlayLayer.contentsScale = scale;
    for (FvpDanmakuItem* item in _live) {
        item.layer.contentsScale = scale;
    }
    for (CATextLayer* layer in _subtitleLayers) {
        layer.contentsScale = scale;
    }
}

/// Height of one track, in points.
- (CGFloat)trackHeight
{
    // One text line tall, measured with the font the comments are drawn in.
    NSDictionary* attributes = [self textAttributesWithColor:[NSColor whiteColor]
                                                 strokeWidth:kDanmakuStrokeWidthPoints];
    return ceil([@"弹幕" sizeWithAttributes:attributes].height * kLineHeight);
}

- (NSInteger)trackCount
{
    CGFloat height = self.bounds.size.height;
    CGFloat trackHeight = [self trackHeight];
    if (height <= 0 || trackHeight <= 0) {
        return 0;
    }
    NSInteger count = (NSInteger)floor(height * _area / trackHeight);
    // The Flutter renderer is configured with `safeArea: true`, which keeps the
    // last track clear of the bottom edge so comments never collide with the
    // control bar; for the full area that amounts to dropping one track.
    if (_area >= 1.0 && count > 0) {
        count -= 1;
    }
    return MAX(count, 0);
}

#pragma mark - Options and content

- (void)setDanmakuList:(NSArray<NSDictionary*>*)list
{
    NSMutableArray<FvpDanmakuItem*>* parsed = [NSMutableArray arrayWithCapacity:list.count];
    for (NSDictionary* entry in list) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        FvpDanmakuItem* item = [FvpDanmakuItem new];
        item.startMs = ((NSNumber*)entry[@"time"]).longLongValue;
        NSString* text = entry[@"text"];
        item.text = [text isKindOfClass:[NSString class]] ? text : @"";
        item.argb = (uint32_t)((NSNumber*)entry[@"color"]).unsignedLongLongValue;
        item.color = [self colorFromARGB:item.argb];
        item.motion = [self motionFromType:((NSNumber*)entry[@"type"]).integerValue];
        if (item.text.length == 0) {
            continue;
        }
        [parsed addObject:item];
    }
    // The timeline walks the list with a single cursor, which only holds if the
    // start times ascend, so an out-of-order payload is put right here.
    [parsed sortUsingComparator:^NSComparisonResult(FvpDanmakuItem* a, FvpDanmakuItem* b) {
        if (a.startMs < b.startMs) return NSOrderedAscending;
        if (a.startMs > b.startMs) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    [self freeStartTimes];
    _items = parsed;
    _itemCount = parsed.count;
    if (_itemCount > 0) {
        _startTimesMs = (int64_t*)malloc(sizeof(int64_t) * _itemCount);
        for (NSUInteger i = 0; i < _itemCount; i++) {
            _startTimesMs[i] = parsed[i].startMs;
        }
    }
    [self measureItems];
    [self removeAllLiveItems];
    [self resetTimeline];
}

- (void)setOptions:(NSDictionary*)options
{
    CGFloat previousFontSize = _fontSize;
    NSString* previousFontName = _fontName;

    NSNumber* fontSize = options[@"fontSize"];
    if (fontSize != nil) {
        _fontSize = MAX(fontSize.doubleValue, 1.0);
    }
    NSNumber* area = options[@"area"];
    if (area != nil) {
        _area = MIN(MAX(area.doubleValue, 0.0), 1.0);
    }
    NSNumber* opacity = options[@"opacity"];
    if (opacity != nil) {
        _opacity = MIN(MAX(opacity.doubleValue, 0.0), 1.0);
    }
    NSNumber* durationMs = options[@"durationMs"];
    if (durationMs != nil) {
        _durationMs = MAX(durationMs.longLongValue, 1);
    }
    NSNumber* staticDurationMs = options[@"staticDurationMs"];
    if (staticDurationMs != nil) {
        _staticDurationMs = MAX(staticDurationMs.longLongValue, 1);
    }
    NSString* fontFamily = options[@"fontFamily"];
    if ([fontFamily isKindOfClass:[NSString class]] && fontFamily.length > 0) {
        _fontName = fontFamily;
    }
    _overlayLayer.opacity = (float)_opacity;

    if (_fontSize != previousFontSize || ![_fontName isEqualToString:previousFontName]) {
        // The measured text widths and the track height both come from the
        // font, so every comment is re-measured. Comments already on screen are
        // dropped rather than restyled mid-flight: their layers are carrying a
        // running animation and the text has to be redrawn at the new size.
        [self measureItems];
        [self removeAllLiveItems];
        [self resetTimeline];
    }
    [self layoutSubtitleLayers];
}

- (void)setDanmakuVisible:(BOOL)visible
{
    _visible = visible;
    _overlayLayer.hidden = !visible;
}

- (void)pauseDanmaku
{
    _running = NO;
}

- (void)resumeDanmaku
{
    // Resume from wherever the player actually is. A paused overlay can be
    // seeked underneath, and continuing from the frozen position would show
    // the wrong comments.
    [self syncPositionFromPlayer];
    _lastPositionMs = _positionMs;
    _hasLastPosition = YES;
    _running = YES;
}

- (void)clearDanmaku
{
    [self removeAllLiveItems];
    [self resetTimeline];
}

/// Rewinds the dispatch cursor to the current playback position.
- (void)resetTimeline
{
    _nextIndex = _itemCount > 0
        ? [self lowerBoundForTarget:_positionMs - kLookBehindMs]
        : 0;
    _lastPositionMs = _positionMs;
    _hasLastPosition = YES;
}

#pragma mark - Playback clock

- (void)startClockIfNeeded
{
    if (_clock != nil || _torndown) {
        return;
    }
    // A comment's position is a pure function of the playback position, so the
    // tick only has to be at least as fine as a frame to look smooth while
    // staying cheap: nothing is redrawn here, comments are repositioned and
    // composited on the GPU.
    _clock = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                     target:self
                                   selector:@selector(onClockTick:)
                                   userInfo:nil
                                    repeats:YES];
    // The player screen scrolls and tracks the pointer constantly; firing only
    // in the default mode would let the comments stutter during interaction.
    [[NSRunLoop mainRunLoop] addTimer:_clock forMode:NSRunLoopCommonModes];
}

- (void)onClockTick:(NSTimer*)timer
{
    if (_torndown || !_running) {
        // Nothing to advance. The clock stays alive so a resume does not have
        // to rebuild it, and the live comments stay exactly where they are.
        return;
    }
    [self syncPositionFromPlayer];
    [self advanceToPosition:_positionMs];
}

- (void)syncPositionFromPlayer
{
    // `position()` reports the currently presented video frame's timestamp,
    // which is what the comments have to line up with — not the audio clock or
    // the demuxer's read position.
    _positionMs = [self positionMs];
}

- (void)advanceToPosition:(int64_t)positionMs
{
    if (_hasLastPosition) {
        int64_t delta = positionMs - _lastPositionMs;
        if (delta < -kBackwardJumpThresholdMs || delta > kForwardJumpThresholdMs) {
            // A seek: the comments on screen belong to a position that is no
            // longer being played, so they are dropped rather than left to
            // finish against unrelated video.
            [self removeAllLiveItems];
            _nextIndex = _itemCount > 0
                ? [self lowerBoundForTarget:positionMs - kLookBehindMs]
                : 0;
        }
    }
    _lastPositionMs = positionMs;
    _hasLastPosition = YES;

    [self dispatchDueAtPosition:positionMs];
    [self retireExpiredItemsAtPosition:positionMs];
}

- (void)dispatchDueAtPosition:(int64_t)positionMs
{
    while (_nextIndex < _itemCount) {
        int64_t startMs = _startTimesMs[_nextIndex];
        if (startMs > positionMs) {
            break;
        }
        FvpDanmakuItem* item = _items[_nextIndex];
        _nextIndex++;
        if (startMs < positionMs - kLookBehindMs) {
            // Too far in the past to still be crossing the screen.
            continue;
        }
        [self presentItem:item atPosition:positionMs];
    }
}

#pragma mark - Presentation

- (void)presentItem:(FvpDanmakuItem*)item atPosition:(int64_t)positionMs
{
    NSInteger track = [self acquireTrackForItem:item atPosition:positionMs];
    if (track < 0) {
        // Every track is busy; the comment is dropped, the same way the Flutter
        // renderer lets an over-subscribed track win.
        return;
    }
    item.track = track;

    if (item.motion == FvpDanmakuMotionScroll) {
        [self presentScrollingItem:item atPosition:positionMs];
    } else {
        [self presentFixedItem:item atPosition:positionMs];
    }
    [_live addObject:item];
}

/// Starts [item] crossing the view.
- (void)presentScrollingItem:(FvpDanmakuItem*)item atPosition:(int64_t)positionMs
{
    CGFloat width = self.bounds.size.width;
    // Travels from fully off the right edge to fully off the left.
    CGFloat travel = width + item.width;
    CFTimeInterval duration = (CFTimeInterval)_durationMs / 1000.0;

    CATextLayer* layer = [self makeLayerForItem:item];
    layer.anchorPoint = CGPointMake(0.0, 0.0);
    layer.bounds = CGRectMake(0, 0, item.width, item.height);
    item.layer = layer;

    item.frameTopY = (CGFloat)(item.track + 1) * [self trackHeight];
    item.frameX = width;
    [self placeLayer:layer forItem:item];
    [_overlayLayer addSublayer:layer];

    // Anchored on the left edge, so the animation runs from the entry point to
    // fully off the left. `fillMode: both` with `removedOnCompletion: NO` keeps
    // the layer at its destination if the overlay ever outlives the animation.
    CABasicAnimation* animation = [CABasicAnimation animationWithKeyPath:@"position.x"];
    animation.fromValue = @(width);
    animation.toValue = @(width - travel);
    animation.duration = duration;
    animation.removedOnCompletion = NO;
    animation.fillMode = kCAFillModeBoth;
    // Constant speed, matching the Flutter renderer's scroll.
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [layer addAnimation:animation forKey:@"scroll"];
}

/// Parks [item] at the top or bottom of its track.
- (void)presentFixedItem:(FvpDanmakuItem*)item atPosition:(int64_t)positionMs
{
    CATextLayer* layer = [self makeLayerForItem:item];
    layer.anchorPoint = CGPointMake(0.0, 0.0);
    layer.bounds = CGRectMake(0, 0, item.width, item.height);
    item.layer = layer;

    CGFloat height = [self trackHeight];
    // A bottom comment occupies the band between the view's bottom edge and one
    // track height above it, so its box hangs up from `height - track*height`.
    item.frameTopY = item.motion == FvpDanmakuMotionTop
        ? (CGFloat)(item.track + 1) * height
        : self.bounds.size.height - (CGFloat)item.track * height;
    item.frameX = floor((self.bounds.size.width - item.width) / 2.0);

    [self placeLayer:layer forItem:item];
    [_overlayLayer addSublayer:layer];
}

- (CATextLayer*)makeLayerForItem:(FvpDanmakuItem*)item
{
    CATextLayer* layer = [CATextLayer layer];
    layer.contentsScale = _overlayLayer.contentsScale;
    layer.wrapped = NO;
    layer.alignmentMode = kCAAlignmentLeft;
    layer.truncationMode = kCATruncationNone;
    layer.string = [self attributedStringForItem:item];
    layer.hidden = !_visible;
    return layer;
}

/// Moves [item]'s layer to the frame recorded on the item.
///
/// The item's own geometry — not the layer's — is the source of truth, so a
/// resize can re-place every comment without asking the layers where they are.
/// Layers are left-anchored, so `position` is the box's left edge.
- (void)placeLayer:(CATextLayer*)layer forItem:(FvpDanmakuItem*)item
{
    layer.position = CGPointMake(item.frameX, item.frameTopY - item.height);
}

- (void)retireItem:(FvpDanmakuItem*)item
{
    [item.layer removeFromSuperlayer];
    item.layer = nil;
    item.track = -1;
    [_live removeObjectIdenticalTo:item];
}

- (void)removeAllLiveItems
{
    for (FvpDanmakuItem* item in _live) {
        [item.layer removeFromSuperlayer];
        item.layer = nil;
        item.track = -1;
    }
    [_live removeAllObjects];
    [_trackReservedUntil removeAllObjects];
}

- (void)retireExpiredItemsAtPosition:(int64_t)positionMs
{
    if (_live.count == 0) {
        return;
    }
    NSMutableArray<FvpDanmakuItem*>* expired = [NSMutableArray array];
    for (FvpDanmakuItem* item in _live) {
        int64_t lifetime = item.motion == FvpDanmakuMotionScroll ? _durationMs : _staticDurationMs;
        if (positionMs - item.startMs >= lifetime) {
            [expired addObject:item];
        }
    }
    for (FvpDanmakuItem* item in expired) {
        [self retireItem:item];
    }
    [self expireTrackReservationsAtPosition:positionMs];
}

#pragma mark - Track allocation

/// Reserves a track for [item], or returns -1 when none is free.
///
/// Scrolling and fixed comments claim tracks on different terms: a scrolling
/// comment may be followed on the same track once it has cleared the right
/// edge, whereas a top/bottom comment holds its track for its whole display
/// time. Both are expressed as a reservation that expires, so one pool covers
/// them.
- (NSInteger)acquireTrackForItem:(FvpDanmakuItem*)item atPosition:(int64_t)positionMs
{
    NSInteger count = [self trackCount];
    if (count <= 0) {
        return -1;
    }
    [self growTrackPoolTo:count];
    for (NSInteger track = 0; track < count; track++) {
        NSNumber* reservedUntil = _trackReservedUntil[track];
        if (reservedUntil != (id)[NSNull null] && reservedUntil.longLongValue > positionMs) {
            continue;
        }
        _trackReservedUntil[track] = @([self reservedUntilForItem:item
                                                         inTrack:track
                                                      atPosition:positionMs]);
        return track;
    }
    return -1;
}

/// When track [track] becomes available again after showing [item].
- (int64_t)reservedUntilForItem:(FvpDanmakuItem*)item
                        inTrack:(NSInteger)track
                     atPosition:(int64_t)positionMs
{
    if (item.motion != FvpDanmakuMotionScroll) {
        return positionMs + _staticDurationMs;
    }
    // The next comment may start once this one has cleared the right edge, i.e.
    // after travelling its own width at the comment's speed.
    CGFloat width = self.bounds.size.width;
    if (width <= 0 || item.width <= 0) {
        return positionMs + _durationMs;
    }
    double speed = (width + item.width) / ((double)_durationMs / 1000.0);
    int64_t enterMs = (int64_t)ceil(item.width / speed * 1000.0);
    return positionMs + enterMs;
}

/// Frees every reservation that has run out.
- (void)expireTrackReservationsAtPosition:(int64_t)positionMs
{
    NSInteger count = [self trackCount];
    [self growTrackPoolTo:count];
    for (NSInteger track = 0; track < count; track++) {
        NSNumber* reservedUntil = _trackReservedUntil[track];
        if (reservedUntil != (id)[NSNull null] && reservedUntil.longLongValue <= positionMs) {
            _trackReservedUntil[track] = [NSNull null];
        }
    }
}

- (void)growTrackPoolTo:(NSInteger)count
{
    while ((NSInteger)_trackReservedUntil.count < count) {
        [_trackReservedUntil addObject:[NSNull null]];
    }
}

#pragma mark - Relayout

- (void)relayoutLiveItems
{
    _overlayLayer.frame = self.bounds;
    NSInteger count = [self trackCount];
    CGFloat height = [self trackHeight];

    for (FvpDanmakuItem* item in _live) {
        NSInteger track = item.track;
        if (track < 0) {
            continue;
        }
        if (track >= count) {
            track = count > 0 ? count - 1 : 0;
            item.track = track;
        }
        if (item.motion == FvpDanmakuMotionBottom) {
            item.frameTopY = self.bounds.size.height - (CGFloat)track * height;
        } else {
            item.frameTopY = (CGFloat)(track + 1) * height;
        }
        if (item.motion != FvpDanmakuMotionScroll) {
            item.frameX = floor((self.bounds.size.width - item.width) / 2.0);
        }
        [self placeLayer:item.layer forItem:item];
    }
}

#pragma mark - Measurement

- (void)measureItems
{
    for (FvpDanmakuItem* item in _items) {
        CGSize size = [self sizeOfText:item.text forItem:item];
        item.width = size.width;
        item.height = size.height;
    }
}

- (CGSize)sizeOfText:(NSString*)text forItem:(FvpDanmakuItem*)item
{
    NSAttributedString* string = [self attributedStringForText:text color:item.color];
    CGSize size = string.size;
    return CGSizeMake(ceil(size.width), ceil(size.height));
}

#pragma mark - Text

- (NSFont*)fontOfSize:(CGFloat)size
{
    NSFont* font = nil;
    if (_fontName.length > 0) {
        font = [NSFont fontWithName:_fontName size:size];
    }
    if (font == nil) {
        // A named family can be unavailable — a locale-dependent font, or one
        // the user removed. The system font still covers CJK.
        font = [NSFont systemFontOfSize:size];
    }
    return font;
}

/// Subtitles render in a heavier weight than danmaku so the white glyphs read
/// clearly against bright video without a thick black stroke. Two weight
/// steps take e.g. PingFang SC Regular to Bold.
- (NSFont*)subtitleFontOfSize:(CGFloat)size
{
    NSFont* font = [self fontOfSize:size];
    NSFontManager* fontManager = [NSFontManager sharedFontManager];
    NSFont* heavier = [fontManager convertWeight:YES ofFont:font];
    heavier = [fontManager convertWeight:YES ofFont:heavier] ?: heavier;
    return heavier ?: font;
}

- (NSDictionary*)textAttributesWithColor:(NSColor*)color strokeWidth:(CGFloat)strokePoints
{
    return @{
        NSFontAttributeName: [self fontOfSize:_fontSize],
        NSForegroundColorAttributeName: color,
        // A negative width means fill AND stroke. The value is a percentage of
        // the font size, so the point-based width is converted here.
        NSStrokeWidthAttributeName: @(-strokePoints / _fontSize * 100.0),
        NSStrokeColorAttributeName: [NSColor blackColor],
    };
}

- (NSAttributedString*)attributedStringForItem:(FvpDanmakuItem*)item
{
    return [self attributedStringForText:item.text color:item.color];
}

- (NSAttributedString*)attributedStringForText:(NSString*)text color:(NSColor*)color
{
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                           attributes:[self textAttributesWithColor:color
                                                                        strokeWidth:kDanmakuStrokeWidthPoints]];
}

- (NSColor*)colorFromARGB:(uint32_t)argb
{
    CGFloat alpha = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat red = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat green = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat blue = (argb & 0xFF) / 255.0;
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

- (FvpDanmakuMotion)motionFromType:(NSInteger)type
{
    switch (type) {
        case FvpDanmakuTypeTop:
            return FvpDanmakuMotionTop;
        case FvpDanmakuTypeBottom:
            return FvpDanmakuMotionBottom;
        default:
            // Reverse scrolling is rendered as a normal scroll, matching the
            // Flutter mapping.
            return FvpDanmakuMotionScroll;
    }
}

#pragma mark - Subtitles

- (void)setSubtitleLines:(NSArray<NSString*>*)lines
                fontSize:(CGFloat)fontSize
           bottomPadding:(CGFloat)bottomPadding
                 opacity:(CGFloat)opacity
{
    for (CATextLayer* layer in _subtitleLayers) {
        [layer removeFromSuperlayer];
    }
    [_subtitleLayers removeAllObjects];
    _subtitleBottomPadding = bottomPadding;

    if (lines.count == 0) {
        return;
    }

    NSFont* font = [self subtitleFontOfSize:fontSize];
    NSDictionary* attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSStrokeWidthAttributeName: @(-kSubtitleStrokeWidthPoints / fontSize * 100.0),
        // A soft, semi-transparent stroke: legibility without a hard edge.
        NSStrokeColorAttributeName: [NSColor colorWithWhite:0.0 alpha:0.6],
    };

    // Lines longer than the video area wrap instead of overflowing the
    // screen; 24pt side margins mirror the Flutter renderer's padding.
    const CGFloat subtitleSideMargin = 24.0;
    const CGFloat minWrapWidth = 80.0;
    CGFloat wrapWidth = MAX(self.bounds.size.width - 2.0 * subtitleSideMargin,
                            minWrapWidth);

    for (NSString* line in lines) {
        if (![line isKindOfClass:[NSString class]] || line.length == 0) {
            continue;
        }
        NSAttributedString* string = [[NSAttributedString alloc] initWithString:line
                                                                     attributes:attributes];
        CGSize singleLineSize = string.size;
        CGSize size = singleLineSize;
        BOOL wraps = singleLineSize.width > wrapWidth;
        if (wraps) {
            CGRect rect = [string boundingRectWithSize:CGSizeMake(wrapWidth, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                               context:nil];
            size = CGSizeMake(wrapWidth, ceil(rect.size.height));
        }
        CATextLayer* layer = [CATextLayer layer];
        layer.contentsScale = _overlayLayer.contentsScale;
        layer.wrapped = wraps;
        layer.alignmentMode = kCAAlignmentCenter;
        layer.truncationMode = kCATruncationNone;
        layer.string = string;
        // Left-anchored so the line can be centred by placing its left edge.
        layer.anchorPoint = CGPointMake(0.0, 0.0);
        layer.bounds = CGRectMake(0, 0, ceil(size.width), ceil(size.height));
        layer.opacity = (float)opacity;
        [_overlayLayer addSublayer:layer];
        [_subtitleLayers addObject:layer];
    }
    [self layoutSubtitleLayers];
}

- (void)layoutSubtitleLayers
{
    if (_subtitleLayers.count == 0) {
        return;
    }
    // The view's layer is not geometry-flipped, so y grows upward and a
    // layer's position (anchorPoint 0,0 = its bottom-left) is its distance
    // from the bottom edge. Anchor the block _subtitleBottomPadding above the
    // bottom edge and stack the lines upward in reading order.
    CGFloat blockHeight = 0;
    for (CATextLayer* layer in _subtitleLayers) {
        blockHeight += layer.bounds.size.height;
    }
    blockHeight += kSubtitleLineGap * (CGFloat)(_subtitleLayers.count - 1);
    CGFloat y = _subtitleBottomPadding + blockHeight;
    for (CATextLayer* layer in _subtitleLayers) {
        CGFloat height = layer.bounds.size.height;
        y -= height;
        layer.position = CGPointMake(floor((self.bounds.size.width - layer.bounds.size.width) / 2.0), y);
        y -= kSubtitleLineGap;
    }
}

#pragma mark - Teardown

- (void)teardown
{
    if (_torndown) {
        return;
    }
    _torndown = YES;
    [_clock invalidate];
    _clock = nil;
    _running = NO;
    [self removeAllLiveItems];
    for (CATextLayer* layer in _subtitleLayers) {
        [layer removeFromSuperlayer];
    }
    [_subtitleLayers removeAllObjects];
    [self freeStartTimes];
    _items = @[];
    _itemCount = 0;
}

- (void)freeStartTimes
{
    if (_startTimesMs != nullptr) {
        free(_startTimesMs);
        _startTimesMs = nullptr;
    }
}

- (void)dealloc
{
    [self teardown];
}

#pragma mark - Binary search

/// Index of the first comment starting at or after [target].
- (NSUInteger)lowerBoundForTarget:(int64_t)target
{
    NSUInteger lower = 0;
    NSUInteger upper = _itemCount;
    while (lower < upper) {
        NSUInteger middle = lower + ((upper - lower) >> 1);
        if (_startTimesMs[middle] < target) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    return lower;
}

@end

#endif // TARGET_OS_OSX