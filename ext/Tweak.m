// TriggrActions - register custom actions in Triggr 2.0 via libtriggr
// SpringBoard only. No hooks; registers actions through libtriggr's public API
// (usage verified against Jond-ie/begonecia Tweak.xm, API surface from
// official Triggr 2.0.0-beta3 libtriggr.dylib strings).
// Action implementations ported verbatim from our proven 1.5.0+cn line.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreHaptics/CoreHaptics.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/stat.h>
#import <string.h>

#define TA_GROUP    @"扩展动作"
#define TA_BACK_NOT "cn.triggr2.back"

static id TAShared(NSString *cls) {
    Class c = NSClassFromString(cls);
    if (!c || ![(id)c respondsToSelector:@selector(sharedInstance)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedInstance));
}

// [1.5.0 cn2.68/2.69 verified] official widget routes, cold-start safe
static void TAOpenURL(NSString *string) {
    NSURL *url = [NSURL URLWithString:string];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {}];
}

// [1.5.0 verified] SBBacklightController screenIsOn
static BOOL TAScreenIsOn(void) {
    id backlight = TAShared(@"SBBacklightController");
    if (!backlight || ![backlight respondsToSelector:@selector(screenIsOn)]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(backlight, @selector(screenIsOn));
}

// 唤醒: only acts on a dark screen (simulated lock press = wake when dark)
static BOOL TAWake(void) {
    id springBoard = UIApplication.sharedApplication;
    if (TAScreenIsOn()) return YES;
    if (![springBoard respondsToSelector:@selector(_simulateLockButtonPress)]) return NO;
    ((void (*)(id, SEL))objc_msgSend)(springBoard, @selector(_simulateLockButtonPress));
    return YES;
}

// [1.5.0, Powercuts-verified]
static BOOL TADismissSiri(void) {
    id ctrl = TAShared(@"SBAssistantController");
    SEL sel = @selector(dismissAssistantViewIfNecessaryWithAnimation:);
    if (!ctrl || ![ctrl respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(ctrl, sel, NO);
    return YES;
}

// [cn4 port] Password unlock: SBLockScreenManager, wake screen first.
static void TAUnlockDevice(NSString *password) {
    id mgr = TAShared(@"SBLockScreenManager");
    if (!mgr) return;
    if ([mgr respondsToSelector:@selector(_wakeScreenForTapToWake)])
        ((void (*)(id, SEL))objc_msgSend)(mgr, @selector(_wakeScreenForTapToWake));
    if ([mgr respondsToSelector:@selector(_attemptUnlockWithPasscode:finishUIUnlock:)])
        ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(mgr, @selector(_attemptUnlockWithPasscode:finishUIUnlock:), password, YES);
}

// Password storage (SB runs as mobile): cn.qwq.triggractions.plist -> unlock
static NSString *TAPrefPath(void) {
    return @"/var/mobile/Library/Preferences/cn.qwq.triggractions.plist";
}
static NSString *TALoadPassword(void) {
    return (NSString *)[NSDictionary dictionaryWithContentsOfFile:TAPrefPath()][@"unlock"];
}
static void TASavePassword(NSString *pw) {
    NSDictionary *dict = @{ @"unlock": pw };
    [dict writeToFile:TAPrefPath() atomically:YES];
    chmod(TAPrefPath().fileSystemRepresentation, 0600);
}

// Popup to set the passcode (cn4-style 弹窗设置密码, on the SB key window).
static void TAPromptPassword(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        if (!window) for (UIWindow *w in UIApplication.sharedApplication.windows) { if (w.isKeyWindow) { window = w; break; } }
        if (!window) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"密码解锁"
            message:@"输入设备的锁屏密码，存储在本机，用于锁屏状态下自动解锁"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"锁屏密码"; tf.secureTextEntry = YES; tf.keyboardType = UIKeyboardTypeNumberPad;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *pw = alert.textFields.firstObject.text;
            if (pw.length) { TASavePassword(pw); TAUnlockDevice(pw); }
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

// ---- libtriggr registration (begonecia pattern: dlopen + NSClassFromString + KVC) ----

static void TARegister(Class infoClass, NSString *identifier, NSString *title, NSString *symbol, void (^handler)(id ctx)) {
    id info = [[infoClass alloc] init];
    [info setValue:identifier forKey:@"identifier"];
    [info setValue:title          forKey:@"title"];
    [info setValue:TA_GROUP       forKey:@"group"];
    [info setValue:symbol         forKey:@"symbolName"];
    id triggr = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"TGTriggr"), @selector(shared));
    if (!triggr) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(triggr, NSSelectorFromString(@"registerAction:handler:"), info, handler);
}

static void TARegisterAll(void) {
    if (!dlopen("libtriggr.dylib", RTLD_NOW)) return; // Triggr 2.0 links it; already in SB
    Class infoClass = NSClassFromString(@"TGActionInfo");
    if (!infoClass || ![NSClassFromString(@"TGTriggr") respondsToSelector:@selector(shared)]) return;

    TARegister(infoClass, @"cn.actions.wxscan",     @"微信扫一扫", @"qrcode.viewfinder", ^(id c) { TAOpenURL(@"weixin://widget/scan"); });
    TARegister(infoClass, @"cn.actions.wxpaycode",  @"微信收付款", @"qrcode",            ^(id c) { TAOpenURL(@"weixin://widget/pay"); });
    TARegister(infoClass, @"cn.actions.aliscan",    @"支付宝扫一扫", @"qrcode.viewfinder", ^(id c) { TAOpenURL(@"alipay3dtouch://platformapi/startapp?appId=10000007&showOthers=YES&sourceId=3dtouch"); });
    TARegister(infoClass, @"cn.actions.alipaycode", @"支付宝付款码", @"qrcode",            ^(id c) { TAOpenURL(@"alipay3dtouch://platformapi/startapp?appId=20000056&src=3dtouch"); });
    TARegister(infoClass, @"cn.actions.wake",       @"唤醒屏幕",   @"sun.max.fill",      ^(id c) { TAWake(); });
    TARegister(infoClass, @"cn.actions.dismisssiri",@"关闭Siri",   @"mic.slash.fill",    ^(id c) { TADismissSiri(); });
    TARegister(infoClass, @"cn.actions.back",       @"返回上级",   @"arrow.uturn.backward", ^(id c) { notify_post(TA_BACK_NOT); });
    TARegister(infoClass, @"cn.actions.unlock",     @"密码解锁",   @"lock.open",         ^(id c) {
        NSString *pw = TALoadPassword();
        if (pw.length) TAUnlockDevice(pw); else TAPromptPassword();
    });
    TARegister(infoClass, @"cn.actions.unlock.set", @"设置解锁密码", @"lock.rotation",   ^(id c) { TAPromptPassword(); });
}

__attribute__((constructor))
static void TAInit(void) {
    if (!strstr(getprogname(), "SpringBoard")) return;
    // Triggr dylib may load after ours; retry on main queue until libtriggr is up.
    __block int tries = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        TARegisterAll();
        if (++tries < 10 && !NSClassFromString(@"TGActionInfo"))
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TARegisterAll(); });
    });
}
