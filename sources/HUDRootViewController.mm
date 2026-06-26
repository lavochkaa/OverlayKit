//
//  HUDRootViewController.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <notify.h>
#include <dlfcn.h>

static int (*s_proc_listallpids)(void *, int);
static int (*s_proc_pidpath)(int, void *, uint32_t);
static int (*s_proc_pidinfo)(int, int, uint64_t, void *, int);

#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#import "HUDRootViewController.h"
#import "HUDMainWindow.h"
#import "UIApplication+Private.h"
#import "LSApplicationProxy.h"
#import "LSApplicationWorkspace.h"
#import "SpringBoardServices.h"
#import "FBSOrientationUpdate.h"
#import "FBSOrientationObserver.h"

#define PROC_PIDTASKINFO         4
#define PROC_PIDPATHINFO_MAXSIZE 4096

struct proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
};

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

static const CGFloat kCircleSize = 44.0;
static const CGFloat kPanelW     = 280.0;
static const CGFloat kPanelH     = 210.0;
static const CGFloat kHeaderH    = 40.0;
static const CGFloat kTabH       = 34.0;

// Passes background touches through to the underlying app
@interface HUDRootView : UIView
@end

@implementation HUDRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center, void *observer, CFStringRef name,
 const void *object, CFDictionaryRef userInfo)
{
    BOOL found = NO;
    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications]) {
        if ([app.applicationIdentifier isEqualToString:@"ch.xxtou.hudapp"]) { found = YES; break; }
    }
    if (!found) [[UIApplication sharedApplication] terminateWithSuccess];
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center, void *observer, CFStringRef name,
 const void *object, CFDictionaryRef userInfo)
{
    HUDRootViewController *vc = (__bridge HUDRootViewController *)observer;
    if ([(__bridge NSString *)name isEqualToString:@NOTIFY_UI_LOCKSTATE]) {
        mach_port_t port = SBSSpringBoardServerPort();
        if (port == MACH_PORT_NULL) return;
        BOOL locked, passcode;
        SBGetScreenLockStatus(port, &locked, &passcode);
        [vc.view setHidden:locked];
    }
}

@interface HUDRootViewController (Troll)
- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration;
@end

@implementation HUDRootViewController {
    // Circle
    UIView  *_circleView;
    CGPoint  _circleCenter;

    // Panel
    UIView   *_panelView;
    CGPoint   _panelCenter;
    BOOL      _isPanelVisible;
    NSInteger _selectedTab;

    // Tabs (UIView + gesture, not UIButton)
    UIView *_cpuTabView;
    UIView *_displayTabView;
    UIView *_tabIndicator;

    // CPU content
    UIView  *_cpuContent;
    UILabel *_cpuValueLabel;
    UIView  *_startStopView;   // tap-gesture button
    UILabel *_startStopLabel;
    BOOL     _isMonitoring;
    NSTimer *_cpuTimer;
    uint64_t _prevCpuNs;
    uint64_t _prevSampleNs;

    // Display content
    UIView  *_displayContent;
    UIView  *_toggleBg;
    UIView  *_toggleThumb;
    BOOL     _screenshotHidden;

    // Orientation
    FBSOrientationObserver *_orientationObserver;
    UIInterfaceOrientation  _orientation;
}

- (void)registerNotifications {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(c, (__bridge const void *)self,
        LaunchServicesApplicationStateChanged, CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(c, (__bridge const void *)self,
        SpringBoardLockStatusChanged, CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self registerNotifications];

        // Load proc functions — fall back to RTLD_DEFAULT if dylib not found separately
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) handle = RTLD_DEFAULT;
        s_proc_listallpids = (int (*)(void *, int))dlsym(handle, "proc_listallpids");
        s_proc_pidpath     = (int (*)(int, void *, uint32_t))dlsym(handle, "proc_pidpath");
        s_proc_pidinfo     = (int (*)(int, int, uint64_t, void *, int))dlsym(handle, "proc_pidinfo");

        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak HUDRootViewController *weak = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *u) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weak updateOrientation:(UIInterfaceOrientation)u.orientation
                      animateWithDuration:u.duration];
            });
        }];
        _screenshotHidden = YES;
    }
    return self;
}

- (void)dealloc {
    [_cpuTimer invalidate];
    [_orientationObserver invalidate];
}

+ (BOOL)passthroughMode { return NO; }
- (void)resetLoopTimer {}
- (void)stopLoopTimer {}

- (void)loadView {
    HUDRootView *v = [[HUDRootView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    CGRect screen = [UIScreen mainScreen].bounds;

    // ── Circle ──────────────────────────────────────────────
    _circleView = [[UIView alloc] initWithFrame:CGRectMake(
        CGRectGetMaxX(screen) - kCircleSize - 16, 120, kCircleSize, kCircleSize)];
    _circleView.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.92];
    _circleView.layer.cornerRadius = kCircleSize / 2;
    _circleView.layer.borderWidth  = 1;
    _circleView.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _circleView.layer.shadowColor  = [UIColor blackColor].CGColor;
    _circleView.layer.shadowOpacity = 0.5;
    _circleView.layer.shadowOffset = CGSizeMake(0, 3);
    _circleView.layer.shadowRadius = 8;
    [self.view addSubview:_circleView];
    _circleCenter = _circleView.center;

    UILabel *icon = [[UILabel alloc] initWithFrame:_circleView.bounds];
    icon.text = @"≡";
    icon.textColor = [UIColor whiteColor];
    icon.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    icon.textAlignment = NSTextAlignmentCenter;
    [_circleView addSubview:icon];

    [_circleView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_circleTapped:)]];
    [_circleView addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_circlePanned:)]];

    // ── Panel ────────────────────────────────────────────────
    CGFloat px = CGRectGetMaxX(screen) - kPanelW - 16;
    _panelView = [[UIView alloc] initWithFrame:CGRectMake(px, 60, kPanelW, kPanelH)];
    _panelView.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.09 alpha:0.96];
    _panelView.layer.cornerRadius = 16;
    _panelView.layer.masksToBounds = YES;
    _panelView.layer.borderWidth = 0.5;
    _panelView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    _panelView.hidden = YES;
    _panelView.alpha  = 0;
    [self.view addSubview:_panelView];
    _panelCenter = _panelView.center;

    [self _buildHeader];
    [self _buildTabs];
    [self _buildCPUContent];
    [self _buildDisplayContent];
    [self _selectTab:0];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    notify_post(NOTIFY_LAUNCHED_HUD);
}

#pragma mark - Panel construction

- (void)_buildHeader {
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kHeaderH)];
    hdr.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.14 alpha:1];
    [_panelView addSubview:hdr];

    UILabel *drag = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 24, kHeaderH)];
    drag.text = @"⠿";
    drag.textColor = [UIColor colorWithWhite:1 alpha:0.25];
    drag.font = [UIFont systemFontOfSize:14];
    [hdr addSubview:drag];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(40, 0, kPanelW - 80, kHeaderH)];
    title.text = @"OverlayKit";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [hdr addSubview:title];

    // Close — UIView + gesture (UIButton doesn't get HUD touches)
    UIView *closeView = [[UIView alloc] initWithFrame:CGRectMake(kPanelW - 44, 0, 44, kHeaderH)];
    UILabel *closeLbl = [[UILabel alloc] initWithFrame:closeView.bounds];
    closeLbl.text = @"✕";
    closeLbl.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    closeLbl.font = [UIFont systemFontOfSize:13];
    closeLbl.textAlignment = NSTextAlignmentCenter;
    [closeView addSubview:closeLbl];
    [closeView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_closePanel)]];
    [hdr addSubview:closeView];

    // Drag header
    [hdr addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panelDragged:)]];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH - 0.5, kPanelW, 0.5)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    [hdr addSubview:sep];
}

- (void)_buildTabs {
    UIView *tabBar = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH, kPanelW, kTabH)];
    tabBar.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1];
    [_panelView addSubview:tabBar];

    CGFloat w = kPanelW / 2;

    _cpuTabView = [self _makeTabView:@"CPU" x:0 width:w action:@selector(_cpuTabTapped)];
    [tabBar addSubview:_cpuTabView];

    _displayTabView = [self _makeTabView:@"Display" x:w width:w action:@selector(_displayTabTapped)];
    [tabBar addSubview:_displayTabView];

    _tabIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, kTabH - 2, w, 2)];
    _tabIndicator.backgroundColor = [UIColor colorWithRed:0.3 green:0.65 blue:1 alpha:1];
    _tabIndicator.layer.cornerRadius = 1;
    [tabBar addSubview:_tabIndicator];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, kTabH - 0.5, kPanelW, 0.5)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    [tabBar addSubview:sep];
}

- (UIView *)_makeTabView:(NSString *)title x:(CGFloat)x width:(CGFloat)w action:(SEL)action {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(x, 0, w, kTabH)];
    UILabel *lbl = [[UILabel alloc] initWithFrame:v.bounds];
    lbl.text = title;
    lbl.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.tag = 99; // tag for color update
    [v addSubview:lbl];
    [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:action]];
    return v;
}

- (void)_buildCPUContent {
    CGFloat y = kHeaderH + kTabH;
    _cpuContent = [[UIView alloc] initWithFrame:CGRectMake(0, y, kPanelW, kPanelH - y)];
    [_panelView addSubview:_cpuContent];

    _cpuValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, kPanelW, 46)];
    _cpuValueLabel.text = @"--.--%";
    _cpuValueLabel.textColor = [UIColor whiteColor];
    _cpuValueLabel.font = [UIFont monospacedSystemFontOfSize:38 weight:UIFontWeightLight];
    _cpuValueLabel.textAlignment = NSTextAlignmentCenter;
    [_cpuContent addSubview:_cpuValueLabel];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, kPanelW, 16)];
    sub.text = @"Foreground app CPU";
    sub.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    sub.font = [UIFont systemFontOfSize:11];
    sub.textAlignment = NSTextAlignmentCenter;
    [_cpuContent addSubview:sub];

    // Start/Stop — UIView + gesture
    CGFloat btnW = 110;
    _startStopView = [[UIView alloc] initWithFrame:CGRectMake((kPanelW - btnW) / 2, 84, btnW, 32)];
    _startStopView.backgroundColor = [UIColor colorWithRed:0.18 green:0.72 blue:0.38 alpha:1];
    _startStopView.layer.cornerRadius = 8;

    _startStopLabel = [[UILabel alloc] initWithFrame:_startStopView.bounds];
    _startStopLabel.text = @"Start";
    _startStopLabel.textColor = [UIColor whiteColor];
    _startStopLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _startStopLabel.textAlignment = NSTextAlignmentCenter;
    [_startStopView addSubview:_startStopLabel];

    [_startStopView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_toggleMonitoring)]];
    [_cpuContent addSubview:_startStopView];
}

- (void)_buildDisplayContent {
    CGFloat y = kHeaderH + kTabH;
    _displayContent = [[UIView alloc] initWithFrame:CGRectMake(0, y, kPanelW, kPanelH - y)];
    _displayContent.hidden = YES;
    [_panelView addSubview:_displayContent];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, kPanelW - 90, 22)];
    lbl.text = @"Hide Screenshot";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:14];
    [_displayContent addSubview:lbl];

    // Custom toggle (UISwitch may also have touch issues in HUD)
    _toggleBg = [[UIView alloc] initWithFrame:CGRectMake(kPanelW - 74, 20, 50, 30)];
    _toggleBg.backgroundColor = [UIColor colorWithRed:0.3 green:0.65 blue:1 alpha:1];
    _toggleBg.layer.cornerRadius = 15;
    [_displayContent addSubview:_toggleBg];

    _toggleThumb = [[UIView alloc] initWithFrame:CGRectMake(22, 3, 24, 24)];
    _toggleThumb.backgroundColor = [UIColor whiteColor];
    _toggleThumb.layer.cornerRadius = 12;
    [_toggleBg addSubview:_toggleThumb];

    [_toggleBg addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_screenshotToggleTapped)]];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 58, kPanelW - 40, 36)];
    hint.text = @"Hides HUD from screenshots\nand screen recordings";
    hint.textColor = [UIColor colorWithWhite:0.42 alpha:1];
    hint.font = [UIFont systemFontOfSize:11];
    hint.numberOfLines = 2;
    [_displayContent addSubview:hint];
}

#pragma mark - Tab switching

- (void)_selectTab:(NSInteger)tab {
    _selectedTab = tab;
    _cpuContent.hidden     = (tab != 0);
    _displayContent.hidden = (tab != 1);

    UIColor *active   = [UIColor colorWithRed:0.3 green:0.65 blue:1 alpha:1];
    UIColor *inactive = [UIColor colorWithWhite:0.45 alpha:1];

    ((UILabel *)[_cpuTabView viewWithTag:99]).textColor     = (tab == 0) ? active : inactive;
    ((UILabel *)[_displayTabView viewWithTag:99]).textColor = (tab == 1) ? active : inactive;

    CGFloat tabW = kPanelW / 2;
    [UIView animateWithDuration:0.2 animations:^{
        CGRect f = self->_tabIndicator.frame;
        f.origin.x = tab * tabW;
        self->_tabIndicator.frame = f;
    }];
}

- (void)_cpuTabTapped     { [self _selectTab:0]; }
- (void)_displayTabTapped { [self _selectTab:1]; }

#pragma mark - Panel show / hide

- (void)_circleTapped:(UITapGestureRecognizer *)sender {
    _isPanelVisible = !_isPanelVisible;
    if (_isPanelVisible) {
        _panelView.hidden = NO;
        _panelView.alpha  = 0;
        _panelView.transform = CGAffineTransformMakeScale(0.92, 0.92);
        [UIView animateWithDuration:0.2 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_panelView.alpha = 1;
            self->_panelView.transform = CGAffineTransformIdentity;
            self->_circleView.alpha = 0;
        } completion:nil];
    } else {
        [self _closePanel];
    }
}

- (void)_closePanel {
    _isPanelVisible = NO;
    [UIView animateWithDuration:0.15 delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self->_panelView.alpha = 0;
        self->_panelView.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL finished) {
        self->_panelView.hidden = YES;
        self->_panelView.transform = CGAffineTransformIdentity;
        [UIView animateWithDuration:0.2 animations:^{
            self->_circleView.alpha = 1;
        }];
    }];
}

#pragma mark - Drag gestures

- (void)_circlePanned:(UIPanGestureRecognizer *)sender {
    CGPoint t = [sender translationInView:self.view];
    CGPoint c = CGPointMake(_circleCenter.x + t.x, _circleCenter.y + t.y);
    CGRect  b = self.view.bounds;
    CGFloat r = kCircleSize / 2;
    c.x = MAX(r, MIN(CGRectGetWidth(b)  - r, c.x));
    c.y = MAX(r, MIN(CGRectGetHeight(b) - r, c.y));
    _circleView.center = c;
    if (sender.state == UIGestureRecognizerStateEnded ||
        sender.state == UIGestureRecognizerStateCancelled) {
        _circleCenter = _circleView.center;
    }
}

- (void)_panelDragged:(UIPanGestureRecognizer *)sender {
    CGPoint t  = [sender translationInView:self.view];
    CGPoint c  = CGPointMake(_panelCenter.x + t.x, _panelCenter.y + t.y);
    CGRect  b  = self.view.bounds;
    CGFloat hw = kPanelW / 2, hh = kPanelH / 2;
    c.x = MAX(hw, MIN(CGRectGetWidth(b)  - hw, c.x));
    c.y = MAX(hh, MIN(CGRectGetHeight(b) - hh, c.y));
    _panelView.center = c;
    if (sender.state == UIGestureRecognizerStateEnded ||
        sender.state == UIGestureRecognizerStateCancelled) {
        _panelCenter = _panelView.center;
    }
}

#pragma mark - CPU monitoring

- (pid_t)_pidForBundleID:(NSString *)bundleID {
    if (!s_proc_listallpids || !s_proc_pidpath) return -1;
    Class cls = objc_getClass("LSApplicationProxy");
    LSApplicationProxy *proxy = [cls applicationProxyForIdentifier:bundleID];
    if (!proxy.bundleURL) return -1;

    NSString *bundlePath = proxy.bundleURL.path;
    NSString *execPath   = [bundlePath stringByAppendingPathComponent:
                            [bundlePath.lastPathComponent stringByDeletingPathExtension]];

    int count = s_proc_listallpids(NULL, 0);
    pid_t *pids = (pid_t *)malloc(count * sizeof(pid_t));
    count = s_proc_listallpids(pids, count * sizeof(pid_t));

    char path[PROC_PIDPATHINFO_MAXSIZE];
    pid_t result = -1;
    for (int i = 0; i < count; i++) {
        memset(path, 0, sizeof(path));
        s_proc_pidpath(pids[i], path, sizeof(path));
        if (strcmp(path, execPath.UTF8String) == 0) { result = pids[i]; break; }
    }
    free(pids);
    return result;
}

- (void)_updateCPU {
    NSString *bundleID = SBSCopyFrontmostApplicationDisplayIdentifier();
    if (!bundleID || !s_proc_pidinfo) { _cpuValueLabel.text = @"--.--%"; return; }

    pid_t pid = [self _pidForBundleID:bundleID];
    if (pid < 0) { _cpuValueLabel.text = @"--.--%"; return; }

    struct proc_taskinfo info;
    if (s_proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sizeof(info)) <= 0) {
        _cpuValueLabel.text = @"--.--%";
        return;
    }

    uint64_t cpuNs = info.pti_total_user + info.pti_total_system;
    uint64_t now   = clock_gettime_nsec_np(CLOCK_MONOTONIC);

    if (_prevCpuNs > 0 && now > _prevSampleNs) {
        float pct = (float)(cpuNs - _prevCpuNs) / (float)(now - _prevSampleNs) * 100.0f;
        _cpuValueLabel.text = [NSString stringWithFormat:@"%.1f%%", MAX(0.f, pct)];
    }
    _prevCpuNs    = cpuNs;
    _prevSampleNs = now;
}

- (void)_toggleMonitoring {
    _isMonitoring = !_isMonitoring;
    if (_isMonitoring) {
        _prevCpuNs = 0;
        _cpuTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                   selector:@selector(_updateCPU)
                                                   userInfo:nil repeats:YES];
        [_cpuTimer fire];
        _startStopView.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1];
        _startStopLabel.text = @"Stop";
    } else {
        [_cpuTimer invalidate];
        _cpuTimer = nil;
        _cpuValueLabel.text = @"--.--%";
        _startStopView.backgroundColor = [UIColor colorWithRed:0.18 green:0.72 blue:0.38 alpha:1];
        _startStopLabel.text = @"Start";
    }
}

#pragma mark - Display / Screenshot toggle

- (void)_screenshotToggleTapped {
    _screenshotHidden = !_screenshotHidden;
    [HUDMainWindow setHideFromScreenshot:_screenshotHidden];

    UIColor *onColor  = [UIColor colorWithRed:0.3 green:0.65 blue:1 alpha:1];
    UIColor *offColor = [UIColor colorWithWhite:0.3 alpha:1];

    [UIView animateWithDuration:0.2 animations:^{
        self->_toggleBg.backgroundColor = self->_screenshotHidden ? onColor : offColor;
        CGRect f = self->_toggleThumb.frame;
        f.origin.x = self->_screenshotHidden ? 22 : 4;
        self->_toggleThumb.frame = f;
    }];
}

@end

@implementation HUDRootViewController (Troll)

static inline CGFloat orientationAngle(UIInterfaceOrientation o) {
    switch (o) {
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        case UIInterfaceOrientationLandscapeLeft:      return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:     return  M_PI_2;
        default:                                       return 0;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation o, CGRect b) {
    switch (o) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, b.size.height, b.size.width);
        default: return b;
    }
}

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration {
    if (orientation == _orientation) return;
    _orientation = orientation;
    CGRect bounds = orientationBounds(orientation, [UIScreen mainScreen].bounds);
    [self.view setBounds:bounds];
    __weak typeof(self) weak = self;
    [UIView animateWithDuration:duration animations:^{
        [weak.view setTransform:CGAffineTransformMakeRotation(orientationAngle(orientation))];
    }];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

@end
