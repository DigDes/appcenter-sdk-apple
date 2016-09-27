/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import "SNMAnalytics.h"
#import "SNMAnalyticsCategory.h"
#import <objc/runtime.h>

static NSString *const kSNMViewControllerSuffix = @"ViewController";

@implementation UIViewController (PageViewLogging)

+ (void)swizzleViewWillAppear {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class class = [self class];

    // Get selectors.
    SEL originalSelector = @selector(viewWillAppear:);
    SEL swizzledSelector = @selector(snm_viewWillAppear:);

    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);

    method_exchangeImplementations(originalMethod, swizzledMethod);
  });
}

#pragma mark - Method Swizzling

- (void)snm_viewWillAppear:(BOOL)animated {
  [self snm_viewWillAppear:animated];
  if ([SNMAnalytics isAutoPageTrackingEnabled]) {

    if (!snm_shouldTrackPageView(self))
      return;

    // By default, use class name for the page name.
    NSString *pageViewName = NSStringFromClass([self class]);

    // Remove module name on swift classes.
    pageViewName = [[pageViewName componentsSeparatedByString:@"."] lastObject];

    // Remove suffix if any.
    if ([pageViewName hasSuffix:kSNMViewControllerSuffix] &&
        [pageViewName length] > [kSNMViewControllerSuffix length]) {
      pageViewName = [pageViewName substringToIndex:[pageViewName length] - [kSNMViewControllerSuffix length]];
    }

    // Track page.
    [SNMAnalytics trackPage:pageViewName withProperties:nil];
  }
}

@end

BOOL snm_shouldTrackPageView(UIViewController *viewController) {

  // For container view controllers, auto page tracking is disabled(to avoid
  // noise).
  NSSet *viewControllerSet = [NSSet setWithArray:@[
    @"UINavigationController",
    @"UITabBarController",
    @"UISplitViewController",
    @"UIInputWindowController",
    @"UIPageViewController"
  ]];
  NSString *className = NSStringFromClass([viewController class]);

  return ![viewControllerSet containsObject:className];
}

@implementation SNMAnalyticsCategory

+ (void)activateCategory {
  [UIViewController swizzleViewWillAppear];
}

@end