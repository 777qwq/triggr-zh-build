// TriggrBackRelay - in-app receiver for the 返回上级 action.
// Injected into all UIKit processes (no hooks; listens on a Darwin notify and
// pops the frontmost navigation/presentation stack). Logic ported verbatim
// from our proven 1.5.0+cn Relay.x (cn2 line).
// Bails out in SpringBoard — the SB side never receives this notify anyway.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>

#define TA_BACK_NOT     "cn.triggr2.back"
#define TA_BACK_ACK     "cn.triggr2.back.ack"

static Class TA_VCClass(void) { return [UIViewController class]; }

static IMP TA_VCBaseEscapeImp(void) {
    static IMP imp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imp = [[TA_VCClass() alloc] methodForSelector:@selector(accessibilityPerformEscape)];
    });
    return imp;
}

// Depth-first search for the first element that truly implements the escape
// (skips UIViewController base-class default implementation).
static BOOL TAEscapeSearch(UIViewController *vc, int depth) {
    if (!vc || depth > 12) return NO;
    if (vc.presentedViewController && TAEscapeSearch(vc.presentedViewController, depth + 1)) return YES;
    SEL sel = @selector(accessibilityPerformEscape);
    if ([vc respondsToSelector:sel] && class_getMethodImplementation([vc class], sel) != TA_VCBaseEscapeImp()) {
        BOOL r = ((BOOL (*)(id, SEL))objc_msgSend)(vc, sel);
        if (r) return YES;
    }
    for (UIViewController *child in vc.childViewControllers)
        if (TAEscapeSearch(child, depth + 1)) return YES;
    return NO;
}

static BOOL TABackSearch(UIViewController *vc, int depth) {
    if (!vc || depth > 12) return NO;
    if (vc.presentedViewController && TABackSearch(vc.presentedViewController, depth + 1)) return YES;
    for (UIViewController *child in vc.childViewControllers)
        if (TABackSearch(child, depth + 1)) return YES;
    UINavigationController *nav = [vc isKindOfClass:[UINavigationController class]] ? (UINavigationController *)vc : vc.navigationController;
    if (nav && nav.viewControllers.count > 1 && nav.topViewController == vc) {
        [nav popViewControllerAnimated:YES]; // standard slide animation (cn1.48 verified)
        return YES;
    }
    if (vc.presentingViewController && vc == vc.presentedViewController) {
        [vc dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    return NO;
}

// Lenient full-tree scan: any visible, poppable navigation stack.
static UINavigationController *TAPoppableNav(UIViewController *vc, int depth) {
    if (!vc || depth > 12) return nil;
    if (vc.presentedViewController) {
        UINavigationController *n = TAPoppableNav(vc.presentedViewController, depth + 1);
        if (n) return n;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UINavigationController *n = TAPoppableNav(child, depth + 1);
        if (n) return n;
    }
    UINavigationController *nav = [vc isKindOfClass:[UINavigationController class]] ? (UINavigationController *)vc : vc.navigationController;
    if (nav && nav.viewControllers.count > 1 && nav.topViewController.viewIfLoaded.window && nav.topViewController == vc)
        return nav;
    if (nav && nav.viewControllers.count > 1 && nav.topViewController.viewIfLoaded.window)
        return nav;
    return nil;
}

static void TARelayDoBack(void) {
    BOOL done = NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (!w.isKeyWindow || !w.rootViewController) continue;
            if (TAEscapeSearch(w.rootViewController, 0)) { done = YES; break; }
        }
        if (done) break;
    }
    if (done) { notify_post(TA_BACK_ACK); return; }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (!w.isKeyWindow || !w.rootViewController) continue;
            if (TABackSearch(w.rootViewController, 0)) { done = YES; break; }
        }
        if (done) break;
    }
    if (!done) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w.rootViewController) continue;
                UINavigationController *nav = TAPoppableNav(w.rootViewController, 0);
                if (nav) { [nav popViewControllerAnimated:YES]; done = YES; break; }
            }
            if (done) break;
        }
    }
    if (done) notify_post(TA_BACK_ACK);
}

__attribute__((constructor))
static void TARelayInit(void) {
    if (strstr(getprogname(), "SpringBoard")) return;
    static int token = -1;
    notify_register_dispatch(TA_BACK_NOT, &token, dispatch_get_main_queue(), ^(int t) {
        TARelayDoBack();
    });
}
