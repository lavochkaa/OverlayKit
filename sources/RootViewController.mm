//
//  RootViewController.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <notify.h>

#import "HUDHelper.h"
#import "MainButton.h"
#import "MainApplication.h"
#import "RootViewController.h"
#import "UIApplication+Private.h"

#define HUD_TRANSITION_DURATION 0.25

static BOOL _gShouldToggleHUDAfterLaunch = NO;

@implementation RootViewController {
    NSMutableDictionary *_userDefaults;
    MainButton *_mainButton;
    BOOL _isRemoteHUDActive;
    UIImpactFeedbackGenerator *_impactFeedbackGenerator;
}

+ (void)setShouldToggleHUDAfterLaunch:(BOOL)flag
{
    _gShouldToggleHUDAfterLaunch = flag;
}

+ (BOOL)shouldToggleHUDAfterLaunch
{
    return _gShouldToggleHUDAfterLaunch;
}

- (BOOL)isHUDEnabled
{
    return IsHUDEnabled();
}

- (void)setHUDEnabled:(BOOL)enabled
{
    SetHUDEnabled(enabled);
}

- (void)registerNotifications
{
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_APP, &token, dispatch_get_main_queue(), ^(int token) {
        [self loadUserDefaults:YES];
    });

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(toggleHUDNotificationReceived:) name:kToggleHUDAfterLaunchNotificationName object:nil];
}

- (void)loadView
{
    CGRect bounds = UIScreen.mainScreen.bounds;

    self.view = [[UIView alloc] initWithFrame:bounds];
    self.view.backgroundColor = [UIColor colorWithRed:0.0f / 255.0f green:0.0f / 255.0f blue:0.0f / 255.0f alpha:.580f / 1.0f];

    self.backgroundView = [[UIView alloc] initWithFrame:bounds];
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if ([traitCollection userInterfaceStyle] == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:28/255.0 green:74/255.0 blue:82/255.0 alpha:1.0];
        } else {
            return [UIColor colorWithRed:26/255.0 green:188/255.0 blue:156/255.0 alpha:1.0];
        }
    }];
    [self.view addSubview:self.backgroundView];

    _mainButton = [MainButton buttonWithType:UIButtonTypeSystem];
    [_mainButton setTintColor:[UIColor whiteColor]];
    [_mainButton addTarget:self action:@selector(tapMainButton:) forControlEvents:UIControlEventTouchUpInside];
    if (@available(iOS 15.0, *))
    {
        UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
        [config setTitleTextAttributesTransformer:^NSDictionary <NSAttributedStringKey, id> * _Nonnull(NSDictionary <NSAttributedStringKey, id> * _Nonnull textAttributes) {
            NSMutableDictionary *newAttributes = [textAttributes mutableCopy];
            [newAttributes setObject:[UIFont boldSystemFontOfSize:32.0] forKey:NSFontAttributeName];
            return newAttributes;
        }];
        [config setCornerStyle:UIButtonConfigurationCornerStyleLarge];
        [_mainButton setConfiguration:config];
    }
    else
    {
        [_mainButton.titleLabel setFont:[UIFont boldSystemFontOfSize:32.0]];
    }
    [self.backgroundView addSubview:_mainButton];

    UILayoutGuide *safeArea = self.backgroundView.safeAreaLayoutGuide;
    [_mainButton setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [_mainButton.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_mainButton.centerYAnchor constraintEqualToAnchor:self.backgroundView.centerYAnchor],
    ]];

    [self reloadMainButtonState];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _impactFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [self registerNotifications];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self toggleHUDAfterLaunch];
}

- (void)toggleHUDNotificationReceived:(NSNotification *)notification {
    NSString *toggleAction = notification.userInfo[kToggleHUDAfterLaunchNotificationActionKey];
    if (!toggleAction) {
        [self toggleHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOn]) {
        [self toggleOnHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOff]) {
        [self toggleOffHUDAfterLaunch];
    }
}

- (void)toggleHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        [self tapMainButton:_mainButton];
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)toggleOnHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (!_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)toggleOffHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)loadUserDefaults:(BOOL)forceReload
{
    if (forceReload || !_userDefaults) {
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
}

- (void)saveUserDefaults
{
    [_userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES];
    notify_post(NOTIFY_RELOAD_HUD);
}

- (void)reloadMainButtonState
{
    _isRemoteHUDActive = [self isHUDEnabled];

    __weak typeof(self) weakSelf = self;
    [UIView transitionWithView:self.backgroundView duration:HUD_TRANSITION_DURATION options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_mainButton setTitle:(strongSelf->_isRemoteHUDActive ? NSLocalizedString(@"Exit HUD", nil) : NSLocalizedString(@"Open HUD", nil)) forState:UIControlStateNormal];
    } completion:nil];
}

- (void)tapMainButton:(UIButton *)sender
{
    BOOL isNowEnabled = [self isHUDEnabled];
    [self setHUDEnabled:!isNowEnabled];
    isNowEnabled = !isNowEnabled;

    if (isNowEnabled)
    {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        [_impactFeedbackGenerator prepare];
        int anyToken;
        __weak typeof(self) weakSelf = self;
        notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &anyToken, dispatch_get_main_queue(), ^(int token) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            notify_cancel(token);
            [strongSelf->_impactFeedbackGenerator impactOccurred];
            dispatch_semaphore_signal(semaphore);
        });

        [self.backgroundView setUserInteractionEnabled:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            intptr_t timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
            dispatch_async(dispatch_get_main_queue(), ^{
                if (timedOut) {
                    log_error(OS_LOG_DEFAULT, "Timed out waiting for HUD to launch");
                }
                [self reloadMainButtonState];
                [self.backgroundView setUserInteractionEnabled:YES];
            });
        });
    }
    else
    {
        [self.backgroundView setUserInteractionEnabled:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reloadMainButtonState];
            [self.backgroundView setUserInteractionEnabled:YES];
        });
    }
}

@end
