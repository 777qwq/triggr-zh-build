// TriggrActions — 第三方动作接入 Triggr 2.0（libtriggr 官方接口标准用法）
//
// ══ 官方接口速查（完整声明见 Triggr 2.0 deb 内 /var/jb/usr/include/triggr/Triggr.h）══
// 链接方式：dlopen("/var/jb/usr/lib/libtriggr.dylib") 或弱链接；先查 TGTriggrAvailable()
// 等价检查：NSClassFromString(@"TGTriggr") 响应 @selector(shared)
//
// TGTriggr（[TGTriggr shared] 单例）仅 4 方法：
//   registerTrigger:(TGTriggerInfo *)            注册触发器
//   registerAction:(TGActionInfo *)handler:(void(^)(TGActionContext *))  注册动作
//   isTriggerAssigned:(NSString *)identifier     该触发器当前有无指派（省电判断用）
//   sendTrigger:(NSString *)identifier           主动触发（任意进程可发，SB 内执行）
// TGActionInfo 属性（KVC setValue:forKey:）：
//   identifier / title / group / symbolName / footer / places
// TGActionContext（handler 入参）：
//   triggerIdentifier / frontmostApp / locked
//
// ⚠ 运行模型：
//   动作在「注册它的进程」内运行——SB tweak 注册的动作在 SpringBoard 内执行。
//   SB 外进程的动作改用 Extensions plist（/Library/Triggr/Extensions，声明式）。
//   触发时引擎按 identifier 到 libtriggr 内存 map 查 handler，查不到=静默失败（无任何日志）。
//
// ⚠ identifier 禁忌（实测 2.0.0-beta9）：
//   toggle. / on. / off. 前缀是引擎原生开关的命名空间（Flipswitch 约定），
//   第三方用此类前缀会被引擎劫持进原生开关表——查无此开关则静默跳过，
//   永远不会调到你的 handler。第三方动作一律用自有前缀 + 动词后缀：
//   例：cn.actions.hotspot.on / cn.actions.hotspot.off
//
// ⚠ 注册时序：tweak 在 ctor 里 dispatch_async(main) 注册即可（本文件 TAInit 的
//   retry 循环处理 libtriggr 晚于本 dylib 加载的情况）。
// ⚠ registry.plist（/var/mobile/Library/Triggr/registry.plist）是 libtriggr 维护的
//   注册元数据，picker 从它读动作列表；移除动作时按 identifier 递归剔除并发
//   com.johndie.triggr/registry-changed 通知（见 TAPruneStaleRegistrations）。
//
// 本文件动作：微信扫一扫/收付款、支付宝扫一扫/收付款、唤醒屏幕、关闭Siri、
// 返回上级、触觉反馈、密码解锁、个人热点开启/关闭（cn.actions.hotspot.on/off，
// 后缀式 id；MISManager 执行体见 TAHotspotSet）。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreHaptics/CoreHaptics.h>
#import <dlfcn.h>
#import <notify.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/stat.h>

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

// ---- 个人热点开/关（cn4.9 配方：MISManager，官方接口标准用法注册） ----
// MISManager 在 WirelessModemSettings.bundle 里，SpringBoard 不链接，手动 dlopen。
// getState:andReason: 位 0 = 开关态；setState: 0x3FF=开 0x3FE=关；已在目标态不重写；
// 首次 setState 常不生效，3 秒后复查重试。主线程直调（仅非主线程才跳板）。
static void TAHotspotDlopen(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings", RTLD_LAZY);
        if (!h) dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings/WirelessModemSettings", RTLD_LAZY);
    });
}

static void TAHotspotSet(BOOL on) { // on=YES 开 / NO 关
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ TAHotspotSet(on); });
        return;
    }
    @try {
        TAHotspotDlopen();
        Class mcls = objc_getClass("MISManager");
        if (!mcls || ![mcls respondsToSelector:@selector(sharedManager)]) { ; return; }
        id m = ((id (*)(id, SEL))objc_msgSend)(mcls, @selector(sharedManager));
        SEL gs = sel_registerName("getState:andReason:"), ss = sel_registerName("setState:");
        if (!m || ![m respondsToSelector:gs] || ![m respondsToSelector:ss]) { ; return; }
        int state = 0, reason = 0;
        ((void (*)(id, SEL, int *, int *))objc_msgSend)(m, gs, &state, &reason);
        if ((state & 1) == (on ? 1 : 0)) { ; return; } // cn4.9 守卫
        ((void (*)(id, SEL, int))objc_msgSend)(m, ss, on ? 0x3ff : 0x3fe);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            int s2 = 0, r2 = 0;
            ((void (*)(id, SEL, int *, int *))objc_msgSend)(m, gs, &s2, &r2);
            if ((s2 & 1) != (on ? 1 : 0)) {
                ((void (*)(id, SEL, int))objc_msgSend)(m, ss, on ? 0x3ff : 0x3fe);
            }
        });
    } @catch (NSException *e) {
    }
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
        @"cn.actions.hotspot", @"cn.actions.ping",
        @"toggle.cn.actions.hotspot", @"on.cn.actions.hotspot", @"off.cn.actions.hotspot",
        @"cn.actions.hotspot.toggle",
    ]];
    BOOL dirty = NO;
    NSDictionary *pruned = TAPruneDict(root, stale, &dirty);
    if (!dirty) return;
    [pruned writeToFile:path atomically:YES];
    notify_post("com.johndie.triggr/registry-changed");
}

// ---- picker row-tap hook: tapping 密码解锁 in the action picker opens the
// cn4.9 config dialog (pre-filled, 取消/保存/移除), like the cn4.9 settings row.
static IMP tgOrigDidSelect = NULL;

static void TAPickerDidSelectIMP(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    // Capture the cell BEFORE the original runs — orig may navigate away and
    // the row disappears (1.9 log: cell=nil when read after orig).
    NSString *hit = nil;
    @try {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if (cell) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
            while (stack.count && !hit) {
                UIView *v = stack.lastObject; [stack removeLastObject];
                for (UIView *sub in v.subviews) [stack addObject:sub];
                if ([v isKindOfClass:[UILabel class]]) {
                    UILabel *l = (UILabel *)v;
                    if ([l.text isEqualToString:@"密码解锁"]) hit = l.text;
                }
            }
        }
    } @catch (NSException *e) { ; }

    if (tgOrigDidSelect) ((void (*)(id, SEL, UITableView *, NSIndexPath *))tgOrigDidSelect)(self, _cmd, tv, ip);

    if (hit) TAPromptPassword();
}

static void TASwizzlePickerRowTap(void) {
    Class picker = NSClassFromString(@"TGActionPickerController");
    if (!picker) { ; return; }
    SEL orig = @selector(tableView:didSelectRowAtIndexPath:);
    Method m1 = class_getInstanceMethod(picker, orig);
    if (!m1) { ; return; }
    if (tgOrigDidSelect) { ; return; }
    tgOrigDidSelect = method_getImplementation(m1);
    // Override on the SUBCLASS only. Never method_exchangeImplementations here:
    // if the picker inherits didSelect from UITableViewController, swapping the
    // Method swaps it for EVERY table view in the process (1.7 crash).
    if (!class_addMethod(picker, orig, (IMP)TAPickerDidSelectIMP, "v@:@@")) {
        // picker implements it locally; replace just this class's IMP
        method_setImplementation(m1, (IMP)TAPickerDidSelectIMP);
    }
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
    TARegister(infoClass, @"cn.actions.hotspot.on",  @"个人热点开启", @"personalhotspot", ^(id c) { TAHotspotSet(YES); });
    TARegister(infoClass, @"cn.actions.hotspot.off", @"个人热点关闭", @"personalhotspot", ^(id c) { TAHotspotSet(NO);  });
}

__attribute__((constructor))
static void TAInit(void) {
    if (strstr(getprogname(), "SpringBoard")) {
        // Triggr dylib may load after ours; retry on main queue until libtriggr is up.
        __block int tries = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            TAPruneStaleRegistrations();
            TARegisterAll();
            if (++tries < 10 && !NSClassFromString(@"TGActionInfo"))
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TARegisterAll(); });
        });
        return;
    }
    // TriggrApp (2.0 app is a shell that loads Triggr.bundle) and Settings.app:
    // hook the picker when Triggr.bundle loads (event-driven, no polling).
    if (strstr(getprogname(), "Preferences") || strstr(getprogname(), "TriggrApp")) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TASwizzlePickerRowTap(); // in case the panel is already open
            [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                id bundle = note.object;
                NSString *bundlePath = [bundle isKindOfClass:[NSBundle class]] ? [(NSBundle *)bundle bundlePath] : nil;
                if (bundlePath.length && [bundlePath containsString:@"Triggr"]) TASwizzlePickerRowTap();
            }];
        });
    }
}
