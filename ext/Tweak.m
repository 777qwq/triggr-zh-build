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

// cn4.9 promptForCommand-style popup (verbatim style): pre-filled existing
// value, 取消/保存/移除(destructive, only when something is stored).
static void TAPromptPassword(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        if (!window) for (UIWindow *w in UIApplication.sharedApplication.windows) { if (w.isKeyWindow) { window = w; break; } }
        if (!window) return;
        NSString *existing = TALoadPassword();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"密码解锁"
            message:@"设备的锁屏密码，存储在本机，用于锁屏状态下自动解锁"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = existing ?: @"";
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *text = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length) TASavePassword(text);
        }]];
        if (existing.length)
            [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                [[NSFileManager defaultManager] removeItemAtPath:TAPrefPath() error:nil];
            }]];
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

// cn4 semantics: the ACTION always just unlocks (main thread — libtriggr's
// handler thread is not guaranteed main, and the SB wake/unlock calls
// silently fail off-main). Password CONFIG happens when the 密码解锁 row is
// tapped in the action picker (see picker swizzle below), like cn4.9's
// settings row. No password stored -> do nothing.
static void TAUnlockAction(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *pw = TALoadPassword();
        if (pw.length) TAUnlockDevice(pw);
    });
}

// [cn4.9 verified] transient haptic (触觉反馈 = light). Main thread only.
static void TAHaptic(double intensity, double sharpness) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static CHHapticEngine *engine;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            if (![[CHHapticEngine capabilitiesForHardware] supportsHaptics]) return;
            NSError *err = nil;
            engine = [[CHHapticEngine alloc] initAndReturnError:&err];
            if (engine) engine.autoShutdownEnabled = YES;
        });
        if (!engine) { [[UISelectionFeedbackGenerator new] selectionChanged]; return; }
        NSError *err = nil;
        if (![engine startAndReturnError:&err]) { [[UISelectionFeedbackGenerator new] selectionChanged]; return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:(float)intensity],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:(float)sharpness]
        ] relativeTime:0];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:&err] : nil;
        if (![player startAtTime:0 error:&err]) [[UISelectionFeedbackGenerator new] selectionChanged];
    });
}

// ---- libtriggr registration (begonecia pattern: dlopen + NSClassFromString + KVC) ----

// Prune stale registrations (removed actions) from registry.plist at any
// nesting depth: {Actions|Triggers: {registrar: {identifier: info}}}.
// Only OUR identifiers are ever touched, so a generic recursive prune is safe.
static NSDictionary *TAPruneDict(NSDictionary *d, NSSet *stale, BOOL *dirty) {
    NSMutableDictionary *out = [d mutableCopy];
    for (NSString *key in d.allKeys) {
        id child = d[key];
        if ([stale containsObject:key]) { [out removeObjectForKey:key]; *dirty = YES; continue; }
        if ([child isKindOfClass:[NSDictionary class]]) out[key] = TAPruneDict(child, stale, dirty);
    }
    return out;
}

static void TAPruneStaleRegistrations(void) {
    NSString *path = @"/var/mobile/Library/Triggr/registry.plist";
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!root) return;
    NSSet *stale = [NSSet setWithArray:@[
        @"cn.actions.screenrecord",
        @"cn.actions.vibrate.light", @"cn.actions.vibrate.medium", @"cn.actions.vibrate.heavy",
        @"cn.actions.unlock.set",
    ]];
    BOOL dirty = NO;
    NSDictionary *pruned = TAPruneDict(root, stale, &dirty);
    if (!dirty) return;
    [pruned writeToFile:path atomically:YES];
    notify_post("com.johndie.triggr/registry-changed");
}

// ---- picker row-tap hook: tapping 密码解锁 in the action picker opens the
// cn4.9 config dialog (pre-filled, 取消/保存/移除), like the cn4.9 settings row.
static void TAPickerDidSelectIMP(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    // original (exchanged) implementation
    ((void (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(self, @selector(tg_didSelectRowAtIndexPath:), tv, ip);
    @try {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if (!cell) return;
        __block NSString *text = nil;
        // custom cells possible: sweep labels in the cell
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        while (stack.count && !text) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            for (UIView *sub in v.subviews) [stack addObject:sub];
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)v;
                if ([l.text isEqualToString:@"密码解锁"]) { text = l.text; break; }
            }
        }
        if (text) TAPromptPassword();
    } @catch (NSException *e) { }
}

static void TASwizzlePickerRowTap(void) {
    Class picker = NSClassFromString(@"TGActionPickerController");
    if (!picker) return;
    SEL orig = @selector(tableView:didSelectRowAtIndexPath:);
    if (!class_getInstanceMethod(picker, orig)) return; // picker not a table delegate: skip silently
    SEL ours = @selector(tg_didSelectRowAtIndexPath:);
    if (!class_addMethod(picker, ours, (IMP)TAPickerDidSelectIMP, "v@:@@")) return;
    Method m1 = class_getInstanceMethod(picker, orig);
    Method m2 = class_getInstanceMethod(picker, ours);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

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
    TARegister(infoClass, @"cn.actions.alipaycode", @"支付宝收付款", @"qrcode",            ^(id c) { TAOpenURL(@"alipay3dtouch://platformapi/startapp?appId=20000056&src=3dtouch"); });
    TARegister(infoClass, @"cn.actions.wake",       @"唤醒屏幕",   @"sun.max.fill",      ^(id c) { TAWake(); });
    TARegister(infoClass, @"cn.actions.dismisssiri",@"关闭Siri",   @"mic.slash.fill",    ^(id c) { TADismissSiri(); });
    TARegister(infoClass, @"cn.actions.back",       @"返回上级",   @"arrow.uturn.backward", ^(id c) { notify_post(TA_BACK_NOT); });
    TARegister(infoClass, @"cn.actions.haptic",     @"触觉反馈",   @"waveform",          ^(id c) { TAHaptic(0.35, 0.7); });
    TARegister(infoClass, @"cn.actions.unlock",     @"密码解锁",   @"lock.open",         ^(id c) { TAUnlockAction(); });
}

__attribute__((constructor))
static void TAInit(void) {
    if (!strstr(getprogname(), "SpringBoard")) return;
    // Triggr dylib may load after ours; retry on main queue until libtriggr is up.
    __block int tries = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        TAPruneStaleRegistrations();
        TARegisterAll();
        TASwizzlePickerRowTap();
        if (++tries < 10 && !NSClassFromString(@"TGActionInfo"))
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TARegisterAll(); });
    });
}
