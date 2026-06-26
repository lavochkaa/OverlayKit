//
//  HUDRootViewController.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <notify.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#import "HUDRootViewController.h"
#import "UIApplication+Private.h"
#import "LSApplicationProxy.h"
#import "LSApplicationWorkspace.h"
#import "SpringBoardServices.h"
#import "FBSOrientationUpdate.h"
#import "FBSOrientationObserver.h"

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

static const CGFloat kCircleSize = 50.0;
static const CGFloat kCircleAlpha = 0.85;

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    BOOL isAppInstalled = NO;
    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications])
    {
        if ([app.applicationIdentifier isEqualToString:@"ch.xxtou.hudapp"])
        {
            isAppInstalled = YES;
            break;
        }
    }
    if (!isAppInstalled) {
        [[UIApplication sharedApplication] terminateWithSuccess];
    }
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE])
    {
        mach_port_t sbsPort = SBSSpringBoardServerPort();
        if (sbsPort == MACH_PORT_NULL) return;

        BOOL isLocked, isPasscodeSet;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);
        [rootViewController.view setHidden:isLocked];
    }
}

@interface HUDRootViewController (Troll)
- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration;
@end

@implementation HUDRootViewController {
    UIView *_circleView;
    UILabel *_injectedLabel;
    FBSOrientationObserver *_orientationObserver;
    UIInterfaceOrientation _orientation;
    CGPoint _circleCenter;
}

- (void)registerNotifications
{
    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwinCenter, (__bridge const void *)self,
        LaunchServicesApplicationStateChanged, CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(darwinCenter, (__bridge const void *)self,
        SpringBoardLockStatusChanged, CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self registerNotifications];
        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak HUDRootViewController *weakSelf = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
            HUDRootViewController *strongSelf = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf updateOrientation:(UIInterfaceOrientation)orientationUpdate.orientation
                          animateWithDuration:orientationUpdate.duration];
            });
        }];
    }
    return self;
}

- (void)dealloc
{
    [_orientationObserver invalidate];
}

+ (BOOL)passthroughMode { return NO; }
- (void)resetLoopTimer {}
- (void)stopLoopTimer {}

- (void)viewDidLoad
{
    [super viewDidLoad];

    CGRect screen = [UIScreen mainScreen].bounds;

    // Circle
    _circleView = [[UIView alloc] initWithFrame:CGRectMake(
        CGRectGetMaxX(screen) - kCircleSize - 20,
        CGRectGetMidY(screen) - kCircleSize / 2,
        kCircleSize, kCircleSize
    )];
    _circleView.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:kCircleAlpha];
    _circleView.layer.cornerRadius = kCircleSize / 2;
    _circleView.layer.shadowColor = [UIColor blackColor].CGColor;
    _circleView.layer.shadowOpacity = 0.3;
    _circleView.layer.shadowOffset = CGSizeMake(0, 2);
    _circleView.layer.shadowRadius = 4;
    [self.view addSubview:_circleView];
    _circleCenter = _circleView.center;

    // "injected" label — shows on tap, fades out
    _injectedLabel = [[UILabel alloc] init];
    _injectedLabel.text = @"injected";
    _injectedLabel.textColor = [UIColor whiteColor];
    _injectedLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _injectedLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    _injectedLabel.textAlignment = NSTextAlignmentCenter;
    _injectedLabel.layer.cornerRadius = 8;
    _injectedLabel.layer.masksToBounds = YES;
    _injectedLabel.alpha = 0.0;
    [_injectedLabel sizeToFit];
    CGRect lf = _injectedLabel.frame;
    lf.size.width += 16;
    lf.size.height += 8;
    _injectedLabel.frame = lf;
    [self.view addSubview:_injectedLabel];
    [self _repositionLabel];

    // Gestures
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tapped:)];
    [_circleView addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panned:)];
    [_circleView addGestureRecognizer:pan];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    notify_post(NOTIFY_LAUNCHED_HUD);
}

- (void)_repositionLabel
{
    CGFloat x = _circleView.frame.origin.x + (_circleView.frame.size.width - _injectedLabel.frame.size.width) / 2;
    CGFloat y = _circleView.frame.origin.y - _injectedLabel.frame.size.height - 8;
    if (y < 0) {
        y = _circleView.frame.origin.y + _circleView.frame.size.height + 8;
    }
    _injectedLabel.frame = CGRectMake(x, y, _injectedLabel.frame.size.width, _injectedLabel.frame.size.height);
}

- (void)_tapped:(UITapGestureRecognizer *)sender
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hideLabel) object:nil];

    _injectedLabel.alpha = 0.0;
    [self _repositionLabel];

    [UIView animateWithDuration:0.2 animations:^{
        self->_injectedLabel.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self performSelector:@selector(_hideLabel) withObject:nil afterDelay:1.5];
    }];
}

- (void)_hideLabel
{
    [UIView animateWithDuration:0.3 animations:^{
        self->_injectedLabel.alpha = 0.0;
    }];
}

- (void)_panned:(UIPanGestureRecognizer *)sender
{
    CGPoint translation = [sender translationInView:self.view];
    CGPoint newCenter = CGPointMake(_circleCenter.x + translation.x, _circleCenter.y + translation.y);

    // Clamp to screen bounds
    CGRect bounds = self.view.bounds;
    CGFloat r = kCircleSize / 2;
    newCenter.x = MAX(r, MIN(CGRectGetWidth(bounds) - r, newCenter.x));
    newCenter.y = MAX(r, MIN(CGRectGetHeight(bounds) - r, newCenter.y));

    _circleView.center = newCenter;
    [self _repositionLabel];

    if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        _circleCenter = _circleView.center;
    }
}

@end

@implementation HUDRootViewController (Troll)

static inline CGFloat orientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        case UIInterfaceOrientationLandscapeLeft:      return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:     return M_PI_2;
        default:                                       return 0;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration
{
    if (orientation == _orientation) return;
    _orientation = orientation;

    CGRect bounds = orientationBounds(orientation, [UIScreen mainScreen].bounds);
    [self.view setBounds:bounds];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration animations:^{
        [weakSelf.view setTransform:CGAffineTransformMakeRotation(orientationAngle(orientation))];
    }];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

@end
