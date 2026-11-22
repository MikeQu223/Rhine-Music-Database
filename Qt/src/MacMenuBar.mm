#include "MacMenuBar.h"
#include "Engine.h"
#include "MacMenuBarSettings.h"
#include "PlaybackQueue.h"
#import <AppKit/AppKit.h>
#include <QFile>
#include <QTimer>
#include <algorithm>
#include <cmath>

namespace {
constexpr CGFloat LyricScrollSpeed = 36;
constexpr NSTimeInterval LyricScrollHold = 1.4;

NSString *componentName(MacMenuBar::Component component) {
    switch (component) {
    case MacMenuBar::Component::Lyrics:
        return @"lyrics";
    case MacMenuBar::Component::Controls:
        return @"controls";
    case MacMenuBar::Component::Favorite:
        return @"favorite";
    case MacMenuBar::Component::Icon:
        return @"icon";
    }
    return @"";
}

QString clock(double milliseconds) {
    const auto seconds = int(std::max(0.0, milliseconds) / 1000);
    return QString::number(seconds / 60).rightJustified(2, '0') + ":" +
           QString::number(seconds % 60).rightJustified(2, '0');
}

NSImage *symbolImage(NSString *name, NSString *description, NSFontWeight weight = NSFontWeightRegular) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:16 weight:weight];
    return [image imageWithSymbolConfiguration:configuration];
}

NSImage *playbackImage(NSString *name, NSString *description) {
    NSImage *image = symbolImage(name, description);
    image.size = NSMakeSize(image.size.width * 0.8, image.size.height);
    return image;
}

NSImage *rhineMenuBarIcon() {
    QFile file(QStringLiteral(":/icons/menubar-infinity.svg"));
    if (!file.open(QIODevice::ReadOnly)) {
        return symbolImage(@"infinity", @"RHINE MUSIC DATABASE");
    }
    const auto bytes = file.readAll();
    NSData *data = [NSData dataWithBytes:bytes.constData() length:bytes.size()];
    auto *image = [[NSImage alloc] initWithData:data];
    image.size = NSMakeSize(16 * image.size.width / image.size.height, 16);
    [image setTemplate:YES];
    return image;
}
}

@interface RhineMacMarqueeTextView : NSView {
    NSString *_text;
    NSFont *_font;
    NSTimer *_timer;
    CGFloat _textWidth;
    CGFloat _offset;
    NSTimeInterval _cycleStart;
}
- (void)updateText:(NSString *)text;
@end

@implementation RhineMacMarqueeTextView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    _font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    _text = @"";
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityStaticTextRole;
    return self;
}

- (NSDictionary<NSAttributedStringKey, id> *)attributes {
    return @{NSFontAttributeName : _font, NSForegroundColorAttributeName : NSColor.labelColor};
}

- (void)updateText:(NSString *)text {
    if ([_text isEqualToString:text]) {
        return;
    }
    _text = [text copy];
    self.accessibilityLabel = _text;
    _textWidth = ceil([_text sizeWithAttributes:self.attributes].width);
    [self restartAnimation];
}

- (void)restartAnimation {
    [_timer invalidate];
    _timer = nil;
    _offset = 0;
    _cycleStart = NSDate.timeIntervalSinceReferenceDate;
    self.needsDisplay = YES;
    if (self.isHiddenOrHasHiddenAncestor || _textWidth <= self.bounds.size.width || !self.window) {
        return;
    }
    _timer = [NSTimer timerWithTimeInterval:1.0 / 30
                                     target:self
                                   selector:@selector(advance:)
                                   userInfo:nil
                                    repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)advance:(NSTimer *)timer {
    Q_UNUSED(timer)
    const CGFloat travel = _textWidth - self.bounds.size.width;
    if (travel <= 0) {
        return;
    }
    const auto now = NSDate.timeIntervalSinceReferenceDate;
    const auto elapsed = now - _cycleStart;
    const auto duration = travel / LyricScrollSpeed;
    CGFloat next = 0;
    if (elapsed >= LyricScrollHold && elapsed < LyricScrollHold + duration) {
        next = (elapsed - LyricScrollHold) * LyricScrollSpeed;
    } else if (elapsed >= LyricScrollHold + duration) {
        next = travel;
    }
    if (elapsed >= LyricScrollHold * 2 + duration) {
        _cycleStart = now;
        next = 0;
    }
    if (next != _offset) {
        _offset = next;
        self.needsDisplay = YES;
    }
}

- (void)setFrameSize:(NSSize)size {
    const bool changed = !NSEqualSizes(self.frame.size, size);
    [super setFrameSize:size];
    if (changed) {
        [self restartAnimation];
    }
}

- (void)setHidden:(BOOL)hidden {
    const bool wasHidden = self.hidden;
    [super setHidden:hidden];
    if (hidden) {
        [_timer invalidate];
        _timer = nil;
        return;
    }
    if (wasHidden) {
        [self restartAnimation];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self restartAnimation];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (_text.length == 0) {
        return;
    }
    CGContextSaveGState(NSGraphicsContext.currentContext.CGContext);
    NSRectClip(self.bounds);
    const auto attributes = self.attributes;
    const auto size = [_text sizeWithAttributes:attributes];
    const CGFloat x =
        _textWidth <= self.bounds.size.width ? floor((self.bounds.size.width - _textWidth) / 2) : -_offset;
    const CGFloat y = floor((self.bounds.size.height - size.height) / 2);
    [_text drawAtPoint:NSMakePoint(x, y) withAttributes:attributes];
    CGContextRestoreGState(NSGraphicsContext.currentContext.CGContext);
}

- (void)dealloc {
    [_timer invalidate];
}
@end

@interface RhineMacMenuBarButton : NSButton {
    NSTrackingArea *_trackingArea;
    BOOL _hovered;
    BOOL _pressed;
}
@end

@implementation RhineMacMenuBarButton
- (void)updateFeedback {
    const CGFloat alpha = !self.enabled ? 0 : (_pressed ? 0.20 : (_hovered ? 0.10 : 0));
    self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:alpha].CGColor;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    Q_UNUSED(event)
    _hovered = YES;
    [self updateFeedback];
}

- (void)mouseExited:(NSEvent *)event {
    Q_UNUSED(event)
    _hovered = NO;
    _pressed = NO;
    [self updateFeedback];
}

- (void)performClick:(id)sender {
    if (!self.enabled) {
        return;
    }

    _pressed = YES;
    [self updateFeedback];
    [super performClick:sender];
    _pressed = NO;
    [self updateFeedback];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self updateFeedback];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateFeedback];
}
@end

@interface RhineMacMenuBarView : NSView {
    MacMenuBarController *_controller;
    NSArray<NSString *> *_items;
    CGFloat _lyricWidth;
    RhineMacMarqueeTextView *_lyrics;
    NSView *_controls;
    RhineMacMenuBarButton *_previous;
    RhineMacMenuBarButton *_play;
    RhineMacMenuBarButton *_next;
    RhineMacMenuBarButton *_favorite;
    RhineMacMenuBarButton *_icon;
    NSString *_playSymbol;
    NSString *_favoriteSymbol;
}
- (instancetype)initWithController:(MacMenuBarController *)controller;
- (BOOL)updateItems:(NSArray<NSString *> *)items lyricWidth:(CGFloat)lyricWidth;
- (CGFloat)desiredWidth;
- (void)statusItemClicked:(NSStatusBarButton *)sender;
- (void)performClickAtPoint:(NSPoint)point;
- (void)updateLyrics:(NSString *)lyrics toolTip:(NSString *)toolTip;
- (void)updatePlayback:(BOOL)playing
               loading:(BOOL)loading
              hasTrack:(BOOL)hasTrack
           canPrevious:(BOOL)canPrevious
               canNext:(BOOL)canNext;
- (void)updateFavorite:(BOOL)canLike liked:(BOOL)liked;
@end

@implementation RhineMacMenuBarView
- (RhineMacMenuBarButton *)buttonWithSymbol:(NSString *)symbol
                                     action:(SEL)action
                                    toolTip:(NSString *)toolTip {
    auto *button = [[RhineMacMenuBarButton alloc] initWithFrame:NSMakeRect(0, 0, 24, 22)];
    button.bordered = NO;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 5;
    const bool playbackControl =
        action == @selector(previous:) || action == @selector(togglePlayback:) || action == @selector(next:);
    button.image = action == @selector(toggleFavorite:)
                       ? symbolImage(symbol, toolTip, NSFontWeightSemibold)
                       : (playbackControl ? playbackImage(symbol, toolTip) : symbolImage(symbol, toolTip));
    [button.image setTemplate:YES];
    button.imageScaling = NSImageScaleNone;
    button.target = self;
    button.action = action;
    button.toolTip = toolTip;
    button.accessibilityLabel = toolTip;
    button.refusesFirstResponder = YES;
    return button;
}

- (instancetype)initWithController:(MacMenuBarController *)controller {
    self = [super initWithFrame:NSZeroRect];
    if (!self) {
        return nil;
    }
    _controller = controller;

    _lyrics = [[RhineMacMarqueeTextView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_lyrics];

    _controls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 78, 22)];
    _previous = [self buttonWithSymbol:@"backward.end.fill" action:@selector(previous:) toolTip:@"上一首"];
    _play = [self buttonWithSymbol:@"play.fill" action:@selector(togglePlayback:) toolTip:@"播放"];
    _next = [self buttonWithSymbol:@"forward.end.fill" action:@selector(next:) toolTip:@"下一首"];
    _previous.frame = NSMakeRect(0, 0, 24, 22);
    _play.frame = NSMakeRect(27, 0, 24, 22);
    _next.frame = NSMakeRect(54, 0, 24, 22);
    [_controls addSubview:_previous];
    [_controls addSubview:_play];
    [_controls addSubview:_next];
    [self addSubview:_controls];

    _favorite = [self buttonWithSymbol:@"heart" action:@selector(toggleFavorite:) toolTip:@"喜欢当前歌曲"];
    [self addSubview:_favorite];

    _icon = [self buttonWithSymbol:@"" action:@selector(activate:) toolTip:@"打开 RHINE MUSIC DATABASE"];
    _icon.image = rhineMenuBarIcon();
    [self addSubview:_icon];
    return self;
}

- (BOOL)updateItems:(NSArray<NSString *> *)items lyricWidth:(CGFloat)lyricWidth {
    if ([_items isEqualToArray:items] && _lyricWidth == lyricWidth) {
        return NO;
    }

    _items = [items copy];
    _lyricWidth = lyricWidth;
    [self invalidateIntrinsicContentSize];
    self.needsLayout = YES;
    return YES;
}

- (CGFloat)widthForItem:(NSString *)item {
    if ([item isEqualToString:@"lyrics"]) {
        return _lyricWidth;
    }
    if ([item isEqualToString:@"controls"]) {
        return 78;
    }
    if ([item isEqualToString:@"icon"]) {
        return 38;
    }
    return 24;
}

- (NSView *)viewForItem:(NSString *)item {
    if ([item isEqualToString:@"lyrics"]) {
        return _lyrics;
    }
    if ([item isEqualToString:@"controls"]) {
        return _controls;
    }
    if ([item isEqualToString:@"favorite"]) {
        return _favorite;
    }
    return _icon;
}

- (CGFloat)desiredWidth {
    if (_items.count == 0) {
        return 0;
    }
    CGFloat width = 12 + (_items.count - 1) * 7;
    for (NSString *item in _items) {
        width += [self widthForItem:item];
    }
    return ceil(width);
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize([self desiredWidth], NSStatusBar.systemStatusBar.thickness);
}

- (void)layout {
    [super layout];
    const auto allItems = @[ @"lyrics", @"controls", @"favorite", @"icon" ];
    for (NSString *item in allItems) {
        if (![_items containsObject:item]) {
            [self viewForItem:item].hidden = YES;
        }
    }
    CGFloat x = 6;
    const CGFloat height = self.bounds.size.height;
    for (NSString *item in _items) {
        NSView *view = [self viewForItem:item];
        const CGFloat width = [self widthForItem:item];
        view.frame = NSMakeRect(x, floor((height - 22) / 2), width, 22);
        view.hidden = NO;
        x += width + 7;
    }
}

- (void)updateLyrics:(NSString *)lyrics toolTip:(NSString *)toolTip {
    [_lyrics updateText:lyrics];
    _lyrics.toolTip = toolTip;
}

- (void)updatePlayback:(BOOL)playing
               loading:(BOOL)loading
              hasTrack:(BOOL)hasTrack
           canPrevious:(BOOL)canPrevious
               canNext:(BOOL)canNext {
    _previous.enabled = canPrevious;
    _next.enabled = canNext;
    _play.enabled = hasTrack && !loading;
    NSString *playSymbol = loading ? @"ellipsis" : (playing ? @"pause.fill" : @"play.fill");
    NSString *playLabel = playing ? @"暂停" : @"播放";
    if (![_playSymbol isEqualToString:playSymbol]) {
        _playSymbol = [playSymbol copy];
        _play.image = playbackImage(playSymbol, playLabel);
        [_play.image setTemplate:YES];
    }
    _play.toolTip = playLabel;
    _play.accessibilityLabel = playLabel;
}

- (void)updateFavorite:(BOOL)canLike liked:(BOOL)liked {
    _favorite.enabled = canLike;
    NSString *favoriteSymbol = liked ? @"heart.fill" : @"heart";
    if (![_favoriteSymbol isEqualToString:favoriteSymbol]) {
        _favoriteSymbol = [favoriteSymbol copy];
        _favorite.image =
            symbolImage(favoriteSymbol, liked ? @"取消喜欢当前歌曲" : @"喜欢当前歌曲", NSFontWeightSemibold);
        [_favorite.image setTemplate:YES];
    }
    _favorite.toolTip = liked ? @"取消喜欢当前歌曲" : @"喜欢当前歌曲";
    _favorite.accessibilityLabel = _favorite.toolTip;
}

- (void)activate:(id)sender {
    Q_UNUSED(sender)
    _controller->activate();
}

- (void)previous:(id)sender {
    Q_UNUSED(sender)
    _controller->previous();
}

- (void)togglePlayback:(id)sender {
    Q_UNUSED(sender)
    _controller->togglePlayback();
}

- (void)next:(id)sender {
    Q_UNUSED(sender)
    _controller->next();
}

- (void)toggleFavorite:(id)sender {
    Q_UNUSED(sender)
    _controller->toggleFavorite();
}

- (NSView *)hitTest:(NSPoint)point {
    Q_UNUSED(point)
    // 整个状态项由系统按钮接收点击，子控件仍保留各自的无障碍动作。
    return nil;
}

- (void)statusItemClicked:(NSStatusBarButton *)sender {
    const auto event = NSApp.currentEvent;
    const bool isLeftClick = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp;
    const bool isControlClick = isLeftClick && (event.modifierFlags & NSEventModifierFlagControl);
    if (event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp || isControlClick) {
        _controller->showContextMenu();
        return;
    }

    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        // 键盘激活整个状态项时，打开主窗口。
        _controller->activate();
        return;
    }

    // macOS 27 转发的状态项事件可能带有错误的窗口内坐标。
    const auto window = sender.window;
    if (window) {
        [self layoutSubtreeIfNeeded];
        const auto windowPoint = [window convertPointFromScreen:NSEvent.mouseLocation];
        [self performClickAtPoint:[self convertPoint:windowPoint fromView:nil]];
    }
}

- (void)performClickAtPoint:(NSPoint)point {
    if (!NSPointInRect(point, self.bounds)) {
        return;
    }
    for (RhineMacMenuBarButton *button in @[ _previous, _play, _next, _favorite, _icon ]) {
        if (!button.isHiddenOrHasHiddenAncestor &&
            NSPointInRect([button convertPoint:point fromView:self], button.bounds)) {
            [button performClick:self];
            return;
        }
    }
    if (!_lyrics.hidden && NSPointInRect(point, _lyrics.frame)) {
        _controller->activate();
    }
}
@end

struct MacMenuBarController::Impl {
    NSStatusItem *statusItem = nil;
    RhineMacMenuBarView *view = nil;
    QString trackKey;
    QString lyricText;
    QString toolTip;
    bool lyricInitialized = false;
    bool playing = false;
    bool loading = false;
    bool hasTrack = false;
    bool canPrevious = false;
    bool canNext = false;
    bool playbackInitialized = false;
    bool canLike = false;
    bool liked = false;
    bool favoriteInitialized = false;
    bool favoriteDirty = true;
    bool refreshScheduled = false;
};

MacMenuBarController::MacMenuBarController(Engine *engine, Action activate, Action contextMenu,
                                           QObject *parent)
    : QObject(parent), m_engine(engine), m_activate(std::move(activate)),
      m_contextMenu(std::move(contextMenu)), m_impl(new Impl) {
    auto &player = m_engine->player();
    connect(&player, &MusicPlayer::changed, this, [this] { scheduleRefresh(); });
    connect(&player.lyrics, &LyricsController::changed, this, [this] { scheduleRefresh(); });
    connect(&m_engine->app->music, &MusicLibrary::invalidated, this, [this] {
        m_impl->favoriteDirty = true;
        scheduleRefresh();
    });
    connect(&m_engine->host, &Host::preferenceChanged, this, [this](const QString &key, const QString &) {
        if (key == QLatin1String(MacMenuBar::LayoutPreference) ||
            key == QLatin1String(MacMenuBar::EnabledPreference) ||
            key == QLatin1String(MacMenuBar::ControlsPreference) ||
            key == QLatin1String(MacMenuBar::IconPreference) ||
            key == QLatin1String(MacMenuBar::WidthPreference)) {
            applyPreferences();
        } else if (key == QLatin1String(MacMenuBar::TranslationPreference)) {
            scheduleRefresh();
        }
    });
    applyPreferences();
}

MacMenuBarController::~MacMenuBarController() {
    removeStatusItem();
    delete m_impl;
}

bool MacMenuBarController::available() const {
    return m_impl->statusItem != nil;
}

/** 合并同一轮事件循环内的播放、歌词和资料库通知，避免重复刷新。 */
void MacMenuBarController::scheduleRefresh() {
    if (!m_impl->view || m_impl->refreshScheduled) {
        return;
    }
    m_impl->refreshScheduled = true;
    QTimer::singleShot(0, this, [this] {
        m_impl->refreshScheduled = false;
        refresh();
    });
}

void MacMenuBarController::removeStatusItem() {
    if (m_impl->statusItem) {
        [NSStatusBar.systemStatusBar removeStatusItem:m_impl->statusItem];
    }
    [m_impl->view removeFromSuperview];
    m_impl->view = nil;
    m_impl->statusItem = nil;
    m_impl->lyricInitialized = false;
    m_impl->playbackInitialized = false;
    m_impl->favoriteInitialized = false;
    m_impl->favoriteDirty = true;
}

/** 实时调整原生状态项的布局和宽度，已有状态项在设置变动时保留原来的系统菜单栏位置。 */
void MacMenuBarController::applyPreferences() {
    const auto &host = m_engine->host;
    const auto storedLayout = MacMenuBar::parseLayout(host.preference(MacMenuBar::LayoutPreference));
    const bool enabled = MacMenuBar::isEnabled(host.preference(MacMenuBar::EnabledPreference));
    const auto layout =
        MacMenuBar::effectiveLayout(storedLayout, enabled, host.preference(MacMenuBar::ControlsPreference),
                                    host.preference(MacMenuBar::IconPreference));
    if (layout.isEmpty()) {
        removeStatusItem();
        return;
    }

    NSMutableArray<NSString *> *items = [NSMutableArray arrayWithCapacity:layout.size()];
    for (const auto item : layout) {
        [items addObject:componentName(item)];
    }

    if (!m_impl->view) {
        m_impl->view = [[RhineMacMenuBarView alloc] initWithController:this];
    }
    const auto lyricWidth = MacMenuBar::parseLyricWidth(host.preference(MacMenuBar::WidthPreference));
    if (![m_impl->view updateItems:items lyricWidth:lyricWidth]) {
        return;
    }

    const auto width = [m_impl->view desiredWidth];
    if (!m_impl->statusItem) {
        m_impl->statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:width];
        NSStatusBarButton *button = m_impl->statusItem.button;
        [button addSubview:m_impl->view];
        button.target = m_impl->view;
        button.action = @selector(statusItemClicked:);
        [button sendActionOn:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown];
        button.accessibilityLabel = @"RHINE MUSIC DATABASE";
    } else if (m_impl->statusItem.length != width) {
        m_impl->statusItem.length = width;
    }
    m_impl->view.frame = NSMakeRect(0, 0, width, NSStatusBar.systemStatusBar.thickness);
    [m_impl->view layoutSubtreeIfNeeded];
    refresh();
}

void MacMenuBarController::refresh() {
    if (!m_impl->view) {
        return;
    }
    const auto &music = m_engine->app->music;
    const auto &player = music.player;
    const auto &track = player.current;
    const bool hasTrack = !track.isEmpty();
    const auto trackKey = PlaybackQueue::identity(track) + '\n' + track["key"].toString();
    if (trackKey != m_impl->trackKey) {
        m_impl->trackKey = trackKey;
        m_impl->favoriteDirty = true;
    }

    // 收藏数据可能遍历较大的 likedIDs；只在切歌或收藏数据失效时重新读取。
    const bool favoriteWasInitialized = m_impl->favoriteInitialized;
    const bool previousCanLike = m_impl->canLike;
    const bool previousLiked = m_impl->liked;
    if (m_impl->favoriteDirty || !m_impl->favoriteInitialized) {
        m_impl->liked = music.songLiked(track).value_or(false);
        m_impl->canLike = hasTrack && track["kind"] == "song" && (music.isSiren() || !music.uid.isEmpty()) &&
                          !music.writeLoading && music.canMutate("/like") &&
                          track.value("provider").toString(music.provider) == music.provider;
        m_impl->favoriteDirty = false;
        m_impl->favoriteInitialized = true;
    }

    const bool useTranslation = MacMenuBar::usesTranslation(
        m_engine->host.preference(MacMenuBar::TranslationPreference));
    auto text = MacMenuBar::lyricText(player.lyrics.document(), player.lyrics.index, useTranslation);
    if (text.isEmpty()) {
        text = track["title"].toString().trimmed();
    }
    if (text.isEmpty()) {
        text = QStringLiteral("RHINE MUSIC DATABASE");
    }
    const auto position = player.state["position"].toDouble();
    const auto duration = player.state["duration"].toDouble();
    QString toolTipText = track["title"].toString();
    const auto artist = track["artist"].toString();
    if (!artist.isEmpty()) {
        toolTipText += (toolTipText.isEmpty() ? QString() : QStringLiteral(" — ")) + artist;
    }
    if (hasTrack) {
        toolTipText += "\n" + clock(position) + " / " + clock(duration);
    }

    if (!m_impl->lyricInitialized || text != m_impl->lyricText || toolTipText != m_impl->toolTip) {
        NSString *toolTip = toolTipText.toNSString();
        [m_impl->view updateLyrics:text.toNSString() toolTip:toolTip];
        m_impl->statusItem.button.toolTip = toolTip;
        m_impl->lyricText = text;
        m_impl->toolTip = toolTipText;
        m_impl->lyricInitialized = true;
    }

    const bool playing = player.state["playing"].toBool();
    const bool loading = player.loading;
    const bool canPrevious = hasTrack && !player.queue.isEmpty();
    const bool canNext = hasTrack && player.queue.nextIndex(player.mode) >= 0;
    if (!m_impl->playbackInitialized || playing != m_impl->playing || loading != m_impl->loading ||
        hasTrack != m_impl->hasTrack || canPrevious != m_impl->canPrevious || canNext != m_impl->canNext) {
        [m_impl->view updatePlayback:playing
                             loading:loading
                            hasTrack:hasTrack
                         canPrevious:canPrevious
                             canNext:canNext];
        m_impl->playing = playing;
        m_impl->loading = loading;
        m_impl->hasTrack = hasTrack;
        m_impl->canPrevious = canPrevious;
        m_impl->canNext = canNext;
        m_impl->playbackInitialized = true;
    }

    if (!favoriteWasInitialized || m_impl->canLike != previousCanLike || m_impl->liked != previousLiked) {
        [m_impl->view updateFavorite:m_impl->canLike liked:m_impl->liked];
    }
}

void MacMenuBarController::activate() {
    if (m_activate) {
        m_activate();
    }
}

void MacMenuBarController::showContextMenu() {
    if (m_contextMenu) {
        m_contextMenu();
    }
}

void MacMenuBarController::previous() {
    m_engine->player().next(-1);
    scheduleRefresh();
}

void MacMenuBarController::togglePlayback() {
    m_engine->player().toggle();
    scheduleRefresh();
}

void MacMenuBarController::next() {
    m_engine->player().next(1);
    scheduleRefresh();
}

void MacMenuBarController::toggleFavorite() {
    auto &music = m_engine->app->music;
    m_impl->favoriteDirty = true;
    music.like(music.player.current);
    scheduleRefresh();
}
