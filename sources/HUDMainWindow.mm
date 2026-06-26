//
//  HUDMainWindow.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

static BOOL s_hideFromScreenshot = YES;

@implementation HUDMainWindow

+ (void)setHideFromScreenshot:(BOOL)hide {
    s_hideFromScreenshot = hide;
}

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return [HUDRootViewController passthroughMode]; }
- (BOOL)_isSecure { return s_hideFromScreenshot; }
- (BOOL)_shouldCreateContextAsSecure { return s_hideFromScreenshot; }

@end
