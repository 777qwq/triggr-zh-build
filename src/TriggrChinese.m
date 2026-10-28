// Triggr 汉化注入库：在显示层把 Triggr 的英文文案替换为中文。
// 不修改 Triggr 本体（2.0.x 已闭源），只做运行时字符串映射。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "dict.h"

static NSString *TGCut(NSString *s) {
    if (s.length <= 48) return s;
    return [s substringToIndex:48];
}

static NSDictionary *gProse;    // 长句、词组：任何上下文都替换
static NSDictionary *gWords;    // 单词：只在 Triggr 自己的界面里替换
static NSArray *gPrefixes;      // 前缀规则（按长度降序），如 "Anywhere: "
static NSArray *gFormats;       // 带占位符的模板
static NSDictionary *gUpper;    // 大写形式 -> 译文（表格分区标题常全大写）
static NSArray *gLongProse;     // 长句（按长度降序）：用于「包含」式兜底匹配

#pragma mark - 模板解析

static BOOL TGIsPlaceholder(NSString *p) {
    if (p.length < 2) return NO;
    unichar c = [p characterAtIndex:0];
    return c == '%' || c == '{';
}

// "电量高于 %@%%" -> [@"电量高于 ", @"%@", @"%"]
static NSArray *TGSplitTemplate(NSString *t) {
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableString *lit = [NSMutableString string];
    NSUInteger i = 0, n = t.length;
    while (i < n) {
        unichar c = [t characterAtIndex:i];
        if (c == '%' && i + 1 < n) {
            unichar d = [t characterAtIndex:i + 1];
            if (d == '%') { [lit appendString:@"%"]; i += 2; continue; }
            if (d == '@' || d == 'd' || d == 'u' || d == 'f' || d == 's' || d == 'l' || d == '0') {
                NSUInteger j = i + 1;
                while (j < n) {
                    unichar e = [t characterAtIndex:j];
                    if (e == '@' || e == 'd' || e == 'u' || e == 'f' || e == 's') break;
                    j++;
                }
                if (j < n) {
                    [parts addObject:[NSString stringWithString:lit]];
                    [lit setString:@""];
                    [parts addObject:[t substringWithRange:NSMakeRange(i, j - i + 1)]];
                    i = j + 1;
                    continue;
                }
            }
        }
        if (c == '{') {
            NSRange close = [t rangeOfString:@"}"];
            if (close.location != NSNotFound && close.location > i) {
                [parts addObject:[NSString stringWithString:lit]];
                [lit setString:@""];
                [parts addObject:[t substringWithRange:NSMakeRange(i, close.location - i + 1)]];
                i = close.location + 1;
                continue;
            }
        }
        [lit appendFormat:@"%C", c];
        i++;
    }
    [parts addObject:[NSString stringWithString:lit]];
    return parts;
}

// 用英文模板匹配运行时的文案，取出占位符的实际值
static NSArray *TGMatchTemplate(NSArray *parts, NSString *input) {
    NSMutableArray *caps = [NSMutableArray array];
    NSUInteger pos = 0, count = parts.count;
    for (NSUInteger k = 0; k < count; k++) {
        NSString *p = [parts objectAtIndex:k];
        if (TGIsPlaceholder(p)) {
            NSString *next = (k + 1 < count) ? [parts objectAtIndex:k + 1] : @"";
            if (TGIsPlaceholder(next)) next = @""; // 相邻占位符：不做细分
            NSRange find;
            if (next.length) find = [input rangeOfString:next options:0 range:NSMakeRange(pos, input.length - pos)];
            else find = NSMakeRange(input.length, 0);
            if (find.location == NSNotFound) return nil;
            NSString *cap = [input substringWithRange:NSMakeRange(pos, find.location - pos)];
            // 护栏：占位符抓到一大段话，说明这不是模板文案（比如长脚注里恰好有 " on "）
            if (cap.length > 48) return nil;
            [caps addObject:cap];
            pos = find.location;
        } else {
            if (pos + p.length > input.length) return nil;
            if (![[input substringWithRange:NSMakeRange(pos, p.length)] isEqualToString:p]) return nil;
            pos += p.length;
        }
    }
    return (pos == input.length) ? caps : nil;
}

static NSString *TGTr(NSString *s);

static NSString *TGFillTemplate(NSArray *parts, NSArray *caps) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger c = 0;
    for (NSUInteger k = 0; k < parts.count; k++) {
        NSString *p = [parts objectAtIndex:k];
        if (TGIsPlaceholder(p)) {
            if (c < caps.count) {
                NSString *v = [caps objectAtIndex:c];
                NSString *tv = TGTr(v); // 参数本身也可能需要翻译（如 "inside Safari"）
                [out appendString:(tv ? tv : v)];
            }
            c++;
        } else {
            [out appendString:p];
        }
    }
    return out;
}

#pragma mark - 翻译

// 前缀模板里的 $ 换成后半段译文，如 "Open $" + "Safari"
static NSString *TGInsert(NSString *tmpl, NSString *rest) {
    NSRange r = [tmpl rangeOfString:@"$"];
    if (r.location == NSNotFound) return [tmpl stringByAppendingString:rest];
    NSString *pre = [tmpl substringWithRange:NSMakeRange(0, r.location)];
    NSString *post = [tmpl substringFromIndex:r.location + 1];
    return [pre stringByAppendingString:[rest stringByAppendingString:post]];
}

// 精确查找：长句 -> 单词 -> 全大写形式（ACTIONS / ADD EVENT 这类表头）
static NSString *TGExact(NSString *s) {
    NSString *hit = [gProse objectForKey:s];
    if (hit) return hit;
    hit = [gWords objectForKey:s];
    if (hit) return hit;
    if (gUpper.count) return [gUpper objectForKey:[s uppercaseString]];
    return nil;
}

// 本体常把两段文案直接拼起来（脚注 + 脚注、触发器组名 + 触发器名），拆开分别翻再拼回去
static NSString *TGComposite(NSString *s) {
    NSUInteger n = s.length;
    if (n < 4) return nil;
    for (NSUInteger i = n - 1; i > 1; i--) {
        NSString *l = [s substringToIndex:i];
        NSString *hl = TGExact(l);
        if (!hl) continue;
        NSString *r = [s substringFromIndex:i];
        NSString *trimmed = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *hr = TGExact(r);
        BOOL gap = NO;
        if (!hr && trimmed.length && trimmed.length != r.length) { hr = TGExact(trimmed); gap = YES; }
        if (!hr) continue;
        if (hl.length <= 12 && hr.length <= 20) return [NSString stringWithFormat:@"%@ %@", hl, hr];
        (void)gap;
        return [hl stringByAppendingString:hr];
    }
    return nil;
}

// 把「A、B、C」这种拼接串逐段翻译；任一段查不到就返回 nil（宁可不翻也别翻一半）
static NSString *TGJoinList(NSString *s, NSString *sep, NSString *join) {
    if (s.length < 4) return nil;
    if ([s rangeOfString:sep].location == NSNotFound) return nil;
    NSArray *parts = [s componentsSeparatedByString:sep];
    if (parts.count < 2 || parts.count > 10) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *t = TGExact([parts objectAtIndex:i]);
        if (!t) return nil;
        [out addObject:t];
    }
    NSMutableString *joined = [NSMutableString string];
    for (NSUInteger i = 0; i < out.count; i++) {
        if (i) [joined appendString:join];
        [joined appendString:[out objectAtIndex:i]];
    }
    return joined;
}

// 星期缩写 -> 中文（定时事件的标题形如「23:37 Sun, Mon, Tue」）
static NSString *TGDayZH(NSString *t) {
    if ([t isEqualToString:@"Sun"] || [t isEqualToString:@"Sunday"]) return @"周日";
    if ([t isEqualToString:@"Mon"] || [t isEqualToString:@"Monday"]) return @"周一";
    if ([t isEqualToString:@"Tue"] || [t isEqualToString:@"Tuesday"]) return @"周二";
    if ([t isEqualToString:@"Wed"] || [t isEqualToString:@"Wednesday"]) return @"周三";
    if ([t isEqualToString:@"Thu"] || [t isEqualToString:@"Thursday"]) return @"周四";
    if ([t isEqualToString:@"Fri"] || [t isEqualToString:@"Friday"]) return @"周五";
    if ([t isEqualToString:@"Sat"] || [t isEqualToString:@"Saturday"]) return @"周六";
    return nil;
}

// 「23:37 Sun, Mon, Tue」-> 「23:37 周日、周一、周二」
static NSString *TGWeekdayList(NSString *s) {
    if (s.length < 3 || s.length > 80) return nil;
    NSArray *parts = [s componentsSeparatedByString:@", "];
    if (parts.count < 2 || parts.count > 7) return nil;
    NSString *first = [parts objectAtIndex:0];
    NSString *head = @"";
    NSUInteger sp = (NSUInteger)-1;
    for (NSUInteger i = first.length; i > 0; i--) {
        if ([first characterAtIndex:i - 1] == ' ') { sp = i - 1; break; }
    }
    if (sp != (NSUInteger)-1) {
        head = [first substringToIndex:sp + 1];
        first = [first substringFromIndex:sp + 1];
    }
    NSString *d = TGDayZH(first);
    if (!d) return nil;
    NSMutableString *out = [NSMutableString stringWithString:head];
    [out appendString:d];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *di = TGDayZH([parts objectAtIndex:i]);
        if (!di) return nil;
        [out appendString:@"、"];
        [out appendString:di];
    }
    return out;
}

static NSString *TGTr(NSString *s) {
    if (s.length == 0) return nil;
    NSString *hit = TGExact(s);
    if (hit) return hit;

    hit = TGWeekdayList(s);
    if (hit) return hit;

    if (s.length <= 140) {
    for (NSUInteger i = 0; i < gFormats.count; i++) {
        NSArray *pair = [gFormats objectAtIndex:i];
        NSArray *caps = TGMatchTemplate([pair objectAtIndex:0], s);
        if (caps) return TGFillTemplate([pair objectAtIndex:1], caps);
    }
    }

    // 已选动作的摘要可能是逗号串（"Last App, App Switcher"）也可能是加号串
    // （"Last App + App Switcher + Lock Device"）：逐段翻，段段都命中才用。
    NSString *lst = TGJoinList(s, @", ", @"、");
    if (lst) return lst;
    lst = TGJoinList(s, @" + ", @" + ");
    if (lst) return lst;

    hit = TGComposite(s);
    if (hit) return hit;

    for (NSUInteger i = 0; i < gPrefixes.count; i++) {
        NSArray *pair = [gPrefixes objectAtIndex:i];
        NSString *en = [pair objectAtIndex:0];
        if (s.length > en.length && [s hasPrefix:en]) {
            NSString *rest = [s substringFromIndex:en.length];
            NSString *r = TGExact(rest);
            if (!r) r = TGTr(rest);
            if (!r) r = rest;
            return TGInsert([pair objectAtIndex:1], r);
        }
    }

    // 兜底：本体在运行时把两段文案拼在一起（脚注 + 脚注、触发器 + 动作），
    // 整句匹配不上时，用「包含」把里面那一整段已知长句换掉。
    if (s.length >= 32) {
        NSString *work = s;
        for (int round = 0; round < 4; round++) {
            BOOL changed = NO;
            for (NSUInteger i = 0; i < gLongProse.count; i++) {
                NSArray *pair = [gLongProse objectAtIndex:i];
                NSString *en = [pair objectAtIndex:0];
                if (en.length > work.length) continue;
                NSRange r = [work rangeOfString:en];
                if (r.location == NSNotFound) continue;
                work = [work stringByReplacingCharactersInRange:r withString:[pair objectAtIndex:1]];
                changed = YES;
                break;
            }
            if (!changed) break;
        }
        if (![work isEqualToString:s]) return work;
    }
    return nil;
}

// 判断类名是否属于 Triggr 自己
static BOOL TGNameIsTriggr(NSString *name) {
    if (!name) return NO;
    if ([name hasPrefix:@"TG"]) return YES;
    return ([name rangeOfString:@"Triggr"].location != NSNotFound);
}

// ---- 判断某个调用地址是不是 Triggr 本体的代码 ----
// 动作横幅 / 提示条是 Triggr.dylib 在 SpringBoard 里画出来的，
// 既不在 Triggr 自己的 VC 下，控件也是普通 UILabel，靠界面结构认不出来。
// 但设置文案的那一帧一定是从 Triggr 的代码里发出来的，用 dladdr 反查即可。
typedef struct TGDLInfo {
    const void *dli_fname;
    const void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} TGDLInfo;
extern int dladdr(const void *addr, TGDLInfo *info);

// 忽略大小写地判断子串
static BOOL TGPathContainsCI(const char *hay, const char *needle) {
    if (!hay || !needle) return NO;
    unsigned long nl = 0;
    while (needle[nl]) nl++;
    if (nl == 0) return NO;
    for (const char *a = hay; *a; a++) {
        const char *b = a, *n = needle;
        while (*n && *b) {
            char c = *b;
            if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
            if (c != *n) break;
            b++; n++;
        }
        if (!*n) return YES;
    }
    return NO;
}

static const void *gSelfBase = NULL;   // 我们自己这个 dylib 的基址

static BOOL TGPathHasTriggr(const char *p) {
    if (!p) return NO;
    return TGPathContainsCI(p, "triggr");
}

static BOOL TGCallerIsTriggr(const void *addr) {
    if (!addr) return NO;
    TGDLInfo info;
    info.dli_fname = 0;
    info.dli_fbase = 0;
    info.dli_sname = 0;
    info.dli_saddr = 0;
    if (dladdr(addr, &info) == 0) return NO;
    // 调用者就是我们自己（把文案转成中文后再 set 回去），不算 Triggr 本体
    if (gSelfBase && info.dli_fbase == gSelfBase) return NO;
    return TGPathHasTriggr(info.dli_fname);
}

// 沿响应链找到最近的 UIViewController
static id TGFindVC(id v) {
    id r = v;
    int depth = 0;
    while (r && depth++ < 32) {
        if ([r isKindOfClass:[UIViewController class]]) return r;
        if (![r respondsToSelector:@selector(nextResponder)]) return nil;
        r = [r nextResponder];
    }
    return nil;
}

static BOOL TGInTriggr(id v) {
    id vc = TGFindVC(v);
    return vc ? TGNameIsTriggr(NSStringFromClass([vc class])) : NO;
}

static BOOL gIsTriggrApp = NO;   // 运行在 Triggr 自己的 App 里
static int  gTriggrVisible = 0;  // 当前屏幕上是否有 Triggr 的页面

static BOOL TGIsTriggrVC(id vc) { return TGNameIsTriggr(NSStringFromClass([vc class])); }

// 视图本身或它的上级视图属于 Triggr。
// 动作横幅是 TriggrRelay 画在 SpringBoard 里的，不在 Triggr 自己的 VC 下，
// 只看响应链会漏掉，所以额外检查视图自身的类名。
static BOOL TGViewIsTriggr(UIView *v) {
    UIView *p = v;
    int depth = 0;
    while (p && depth++ < 16) {
        if (TGNameIsTriggr(NSStringFromClass([p class]))) return YES;
        p = [p superview];
    }
    return NO;
}

// 只在 Triggr 自己的界面里替换，避免影响系统界面
// caller 是设置这段文案的那段代码的返回地址；属于 Triggr 本体就放行
static BOOL TGAllowedCtx(id ctx, const void *caller) {
    if (gIsTriggrApp) return YES;
    if (gTriggrVisible > 0) return YES;
    if (caller && TGCallerIsTriggr(caller)) return YES;
    if (!ctx) return NO;
    if (TGInTriggr(ctx)) return YES;
    if ([ctx isKindOfClass:[UIView class]] && TGViewIsTriggr((UIView *)ctx)) return YES;
    return NO;
}

static BOOL TGAllowed(id ctx) { return TGAllowedCtx(ctx, NULL); }

static NSString *TGTranslateC(NSString *s, id ctx, const void *caller) {
    if (s == nil) return nil;
    if (![s isKindOfClass:[NSString class]]) return s;
    if (s.length == 0) return s;

    BOOL ok = TGAllowedCtx(ctx, caller);
    NSString *hit = nil;
    if (ok) {
        hit = TGTr(s);
        if (!hit) hit = [gWords objectForKey:s];
        if (!hit) {
            // 有些文案带尾部空格/换行，去掉后再试一次
            NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length && t.length != s.length) hit = TGTr(t);
        }
    }
    return hit ? hit : s;
}

static NSString *TGTranslate(NSString *s, id ctx) { return TGTranslateC(s, ctx, NULL); }

static NSAttributedString *TGAttrC(NSAttributedString *as, id ctx, const void *caller) {
    if (!as) return as;
    NSString *orig = [as string];
    if (orig.length == 0) return as;
    NSString *zh = TGTranslateC(orig, ctx, caller);
    if (!zh || [zh isEqualToString:orig]) return as;
    NSDictionary *attrs = [as attributesAtIndex:0 effectiveRange:NULL];
    return [[NSMutableAttributedString alloc] initWithString:zh attributes:attrs];
}

static NSAttributedString *TGAttr(NSAttributedString *as, id ctx) {
    return TGAttrC(as, ctx, NULL);
}

// 翻一个控件本身（不递归）
static void TGTranslateView(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSString *t = [l text];
        if (t.length) {
            NSString *zh = TGTranslate(t, l);
            if (![zh isEqualToString:t]) [l setText:zh];
        } else if ([l attributedText].length) {
            NSAttributedString *as = TGAttr([l attributedText], l);
            if (![[as string] isEqualToString:[[l attributedText] string]]) [l setAttributedText:as];
        }
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) {
            NSString *zh = TGTranslate(t, b);
            if (![zh isEqualToString:t]) [b setTitle:zh forState:UIControlStateNormal];
        }
    } else if ([v isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *sc = (UISegmentedControl *)v;
        NSUInteger n = [sc numberOfSegments];
        for (NSUInteger i = 0; i < n; i++) {
            NSString *t = [sc titleForSegmentAtIndex:i];
            if (!t.length) continue;
            NSString *zh = TGTranslate(t, sc);
            if (![zh isEqualToString:t]) [sc setTitle:zh forSegmentAtIndex:i];
        }
    } else if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;
        NSString *t = [tv text];
        if (t.length) {
            NSString *zh = TGTranslate(t, tv);
            if (![zh isEqualToString:t]) [tv setText:zh];
        } else if ([tv attributedText].length) {
            NSAttributedString *as = TGAttr([tv attributedText], tv);
            if (![[as string] isEqualToString:[[tv attributedText] string]]) [tv setAttributedText:as];
        }
    } else if ([v isKindOfClass:[UITextField class]]) {
        UITextField *f = (UITextField *)v;
        NSString *t = [f text];
        if (t.length) {
            NSString *zh = TGTranslate(t, f);
            if (![zh isEqualToString:t]) [f setText:zh];
        }
    }
}

// 星期网格是程序画的圆形按钮，标题是 S M T W T F S 七个单字母。
// 直接查词表不行（S 既代表周日又代表周六），只能整排按位置换。
static BOOL gWeekdayBusy = NO;

static NSString *TGTextOfView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return [(UILabel *)v text];
    if ([v isKindOfClass:[UIButton class]]) return [(UIButton *)v titleForState:UIControlStateNormal];
    return nil;
}

static BOOL TGWeekdayGrid(UIView *container) {
    if (!container || gWeekdayBusy) return NO;
    NSArray *kids = [container subviews];
    if (kids.count < 7) return NO;
    NSMutableArray *views = [NSMutableArray array];
    for (NSUInteger i = 0; i < kids.count && views.count < 7; i++) {
        UIView *k = [kids objectAtIndex:i];
        NSString *t = TGTextOfView(k);
        if (t.length == 1 && ![t isEqualToString:@" "]) {
            [views addObject:k];
        } else if (views.count > 0) {
            return NO;   // 中间断了，不是这一排
        }
    }
    if (views.count != 7) return NO;
    NSMutableString *seq = [NSMutableString string];
    for (NSUInteger i = 0; i < 7; i++) [seq appendString:TGTextOfView([views objectAtIndex:i])];
    if (![seq isEqualToString:@"SMTWTFS"]) return NO;
    NSString *zh = @"日一二三四五六";
    gWeekdayBusy = YES;
    for (NSUInteger i = 0; i < 7; i++) {
        NSString *c = [zh substringWithRange:NSMakeRange(i, 1)];
        UIView *k = [views objectAtIndex:i];
        if ([k isKindOfClass:[UILabel class]]) [(UILabel *)k setText:c];
        else if ([k isKindOfClass:[UIButton class]]) [(UIButton *)k setTitle:c forState:UIControlStateNormal];
    }
    gWeekdayBusy = NO;
    return YES;
}

// 整棵子树补翻一遍（此时 cell 可能还没挂到窗口上，setText: 触发时拿不到上下文）
static void TGTranslateTree(UIView *v) {
    if (!v) return;
    TGWeekdayGrid(v);
    TGTranslateView(v);
    NSArray *kids = [v subviews];
    for (NSUInteger i = 0; i < kids.count; i++) TGTranslateTree([kids objectAtIndex:i]);
}

#pragma mark - 钩子

static void TGChineseInit(void);

@interface UILabel (TriggrChinese)
- (void)tg_setText:(NSString *)text;
- (void)tg_setAttributedText:(NSAttributedString *)text;
@end

@interface UIButton (TriggrChinese)
- (void)tg_setTitle:(NSString *)title forState:(UIControlState)state;
- (void)tg_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
@end

@interface UINavigationItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title;
@end

@interface UIViewController (TriggrChinese)
- (void)tg_setTitle:(NSString *)title;
- (void)tg_viewDidAppear:(BOOL)animated;
- (void)tg_viewWillDisappear:(BOOL)animated;
@end

@interface UISegmentedControl (TriggrChinese)
- (void)tg_setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment;
@end

@interface UITextField (TriggrChinese)
- (void)tg_setText:(NSString *)text;
- (void)tg_setPlaceholder:(NSString *)text;
@end

@interface UISearchBar (TriggrChinese)
- (void)tg_setPlaceholder:(NSString *)text;
@end

@interface UITextView (TriggrChinese)
- (void)tg_setText:(NSString *)text;
- (void)tg_setAttributedText:(NSAttributedString *)text;
@end

@interface UIBarButtonItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title;
@end

@interface UITabBarItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title;
@end

@interface UIAlertController (TriggrChinese)
+ (id)tg_alertWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
@end

@interface UIAlertAction (TriggrChinese)
+ (id)tg_actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(id))handler;
@end

@interface UIView (TriggrChinese)
+ (void)load;
- (void)tg_didMoveToWindow;
@end

@implementation UILabel (TriggrChinese)
- (void)tg_setText:(NSString *)text {
    [self tg_setText:TGTranslateC(text, self, __builtin_return_address(0))];
    if (text.length == 1) TGWeekdayGrid([self superview]);
}
- (void)tg_setAttributedText:(NSAttributedString *)text {
    [self tg_setAttributedText:TGAttrC(text, self, __builtin_return_address(0))];
}
@end

@implementation UIButton (TriggrChinese)
- (void)tg_setTitle:(NSString *)title forState:(UIControlState)state {
    [self tg_setTitle:TGTranslateC(title, self, __builtin_return_address(0)) forState:state];
    if (title.length == 1) TGWeekdayGrid([self superview]);
}
- (void)tg_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    [self tg_setAttributedTitle:TGAttrC(title, self, __builtin_return_address(0)) forState:state];
}
@end

@implementation UINavigationItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title {
    [self tg_setTitle:TGTranslateC(title, nil, __builtin_return_address(0))];
}
@end

@implementation UISegmentedControl (TriggrChinese)
- (void)tg_setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment {
    [self tg_setTitle:TGTranslateC(title, self, __builtin_return_address(0)) forSegmentAtIndex:segment];
}
@end

@implementation UITextField (TriggrChinese)
- (void)tg_setText:(NSString *)text {
    [self tg_setText:TGTranslateC(text, self, __builtin_return_address(0))];
}
- (void)tg_setPlaceholder:(NSString *)text {
    [self tg_setPlaceholder:TGTranslateC(text, self, __builtin_return_address(0))];
}
@end

@implementation UISearchBar (TriggrChinese)
- (void)tg_setPlaceholder:(NSString *)text {
    [self tg_setPlaceholder:TGTranslateC(text, self, __builtin_return_address(0))];
}
@end

@implementation UITextView (TriggrChinese)
- (void)tg_setText:(NSString *)text {
    [self tg_setText:TGTranslateC(text, self, __builtin_return_address(0))];
}
- (void)tg_setAttributedText:(NSAttributedString *)text {
    [self tg_setAttributedText:TGAttrC(text, self, __builtin_return_address(0))];
}
@end

// 任何视图挂到窗口上时兜底翻一次：这样不依赖具体是哪个 setter 赋的值
@implementation UIBarButtonItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title {
    [self tg_setTitle:TGTranslateC(title, nil, __builtin_return_address(0))];
}
@end

@implementation UITabBarItem (TriggrChinese)
- (void)tg_setTitle:(NSString *)title {
    [self tg_setTitle:TGTranslateC(title, nil, __builtin_return_address(0))];
}
@end

// 弹窗的标题/正文是在 init 里给的，等不到 setter，只能在构造处拦
@implementation UIAlertController (TriggrChinese)
+ (id)tg_alertWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    const void *caller = __builtin_return_address(0);
    if (gIsTriggrApp || gTriggrVisible > 0 || TGCallerIsTriggr(caller)) {
        title = TGTranslateC(title, nil, caller);
        message = TGTranslateC(message, nil, caller);
    }
    return [self tg_alertWithTitle:title message:message preferredStyle:style];
}
@end

@implementation UIAlertAction (TriggrChinese)
+ (id)tg_actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(id))handler {
    const void *caller = __builtin_return_address(0);
    if (gIsTriggrApp || gTriggrVisible > 0 || TGCallerIsTriggr(caller)) title = TGTranslateC(title, nil, caller);
    return [self tg_actionWithTitle:title style:style handler:handler];
}
@end

@implementation UIView (TriggrChinese)
// 兜底入口：即便 __mod_init_func / __init_offsets 没被 dyld 执行，+load 也一定会跑
+ (void)load { TGChineseInit(); }
- (void)tg_didMoveToWindow {
    [self tg_didMoveToWindow];
    if ([self window] != nil && TGAllowed(self)) {
        TGTranslateView(self);
        TGWeekdayGrid([self superview]);
        TGWeekdayGrid(self);
    }
}
@end

@implementation UIViewController (TriggrChinese)
- (void)tg_setTitle:(NSString *)title {
    [self tg_setTitle:TGTranslate(title, self)];
}
- (void)tg_viewDidAppear:(BOOL)animated {
    [self tg_viewDidAppear:animated];
    if (TGIsTriggrVC(self)) {
        gTriggrVisible++;
        TGTranslateTree([self view]);
    }
}
- (void)tg_viewWillDisappear:(BOOL)animated {
    if (TGIsTriggrVC(self) && gTriggrVisible > 0) gTriggrVisible--;
    [self tg_viewWillDisappear:animated];
}
@end

static BOOL TGSwizzle(Class cls, SEL orig, SEL repl) {
    Method a = class_getInstanceMethod(cls, orig);
    Method b = class_getInstanceMethod(cls, repl);
    if (a && b) { method_exchangeImplementations(a, b); return YES; }
    return NO;
}

static BOOL TGSwizzleClass(Class cls, SEL orig, SEL repl) {
    Method a = class_getClassMethod(cls, orig);
    Method b = class_getClassMethod(cls, repl);
    if (a && b) { method_exchangeImplementations(a, b); return YES; }
    return NO;
}

static NSInteger TGComparePrefix(id a, id b, void *ctx) {
    NSUInteger la = [[(NSArray *)a objectAtIndex:0] length];
    NSUInteger lb = [[(NSArray *)b objectAtIndex:0] length];
    if (la == lb) return NSOrderedSame;
    return (la > lb) ? NSOrderedAscending : NSOrderedDescending;
}

static int gInitDone = 0;

static void TGChineseInit(void) {
    if (gInitDone) return;
    gInitDone = 1;

    NSMutableDictionary *prose = [NSMutableDictionary dictionary];
    NSMutableDictionary *words = [NSMutableDictionary dictionary];
    NSMutableArray *prefixes = [NSMutableArray array];
    NSMutableArray *formats = [NSMutableArray array];

    for (int i = 0; kPairs[i][0]; i++) {
        NSString *en = [NSString stringWithUTF8String:kPairs[i][0]];
        NSString *zh = [NSString stringWithUTF8String:kPairs[i][1]];
        if ([en containsString:@"%"] || [en containsString:@"{"]) {
            [formats addObject:[NSArray arrayWithObjects:TGSplitTemplate(en), TGSplitTemplate(zh), nil]];
        } else if ([en hasSuffix:@" "]) {
            [prefixes addObject:[NSArray arrayWithObjects:en, zh, nil]];
        } else if ([en rangeOfString:@" "].location == NSNotFound && en.length < 12) {
            [words setObject:zh forKey:en];
        } else {
            [prose setObject:zh forKey:en];
        }
    }
    NSMutableDictionary *upper = [NSMutableDictionary dictionary];
    NSArray *pk = [prose allKeys];
    for (NSUInteger pi = 0; pi < pk.count; pi++) { NSString *k = [pk objectAtIndex:pi];
        if (k.length < 40) [upper setObject:[prose objectForKey:k] forKey:[k uppercaseString]];
    }
    NSArray *wk = [words allKeys];
    for (NSUInteger wi = 0; wi < wk.count; wi++) { NSString *k = [wk objectAtIndex:wi];
        if (k.length < 40) [upper setObject:[words objectForKey:k] forKey:[k uppercaseString]];
    }
    gUpper = [upper copy];

    gProse = [prose copy];
    gWords = [words copy];

    // 长句表：长度 >= 32 的整句，供「包含」式兜底
    NSMutableArray *longs = [NSMutableArray array];
    NSArray *pk2 = [prose allKeys];
    for (NSUInteger pi2 = 0; pi2 < pk2.count; pi2++) {
        NSString *k = [pk2 objectAtIndex:pi2];
        if (k.length >= 32) [longs addObject:[NSArray arrayWithObjects:k, [prose objectForKey:k], nil]];
    }
    [longs sortUsingFunction:TGComparePrefix context:NULL];
    gLongProse = [longs copy];
    gPrefixes = [prefixes sortedArrayUsingFunction:TGComparePrefix context:NULL];
    gFormats = [formats copy];

    // 记录自己的镜像基址，用来把「我们自己设的文案」排除掉
    {
        TGDLInfo self;
        self.dli_fname = 0;
        self.dli_fbase = 0;
        self.dli_sname = 0;
        self.dli_saddr = 0;
        if (dladdr((const void *)&TGCallerIsTriggr, &self) == 0) self.dli_fbase = 0;
        gSelfBase = self.dli_fbase;
    }

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    // 2.0.x 的 bundle id 是 com.johndie.triggr.app，1.x 是 com.johndie.TriggrApp，两种都认
    gIsTriggrApp = (bid && ([bid rangeOfString:@"triggr" options:1 range:NSMakeRange(0, bid.length)].location != NSNotFound));

    BOOL s1  = TGSwizzle([UILabel class], @selector(setText:), @selector(tg_setText:));
    BOOL s2  = TGSwizzle([UILabel class], @selector(setAttributedText:), @selector(tg_setAttributedText:));
    BOOL s3  = TGSwizzle([UIButton class], @selector(setTitle:forState:), @selector(tg_setTitle:forState:));
    BOOL s4  = TGSwizzle([UIButton class], @selector(setAttributedTitle:forState:), @selector(tg_setAttributedTitle:forState:));
    BOOL s5  = TGSwizzle([UINavigationItem class], @selector(setTitle:), @selector(tg_setTitle:));
    BOOL s6  = TGSwizzle([UISegmentedControl class], @selector(setTitle:forSegmentAtIndex:), @selector(tg_setTitle:forSegmentAtIndex:));
    BOOL s7  = TGSwizzle([UIViewController class], @selector(viewDidAppear:), @selector(tg_viewDidAppear:));
    BOOL s8  = TGSwizzle([UIViewController class], @selector(viewWillDisappear:), @selector(tg_viewWillDisappear:));
    BOOL s9  = TGSwizzle([UIViewController class], @selector(setTitle:), @selector(tg_setTitle:));
    BOOL s10 = TGSwizzle([UITextField class], @selector(setText:), @selector(tg_setText:));
    BOOL s11 = TGSwizzle([UITextField class], @selector(setPlaceholder:), @selector(tg_setPlaceholder:));
    BOOL s12 = TGSwizzle([UISearchBar class], @selector(setPlaceholder:), @selector(tg_setPlaceholder:));
    BOOL s13 = TGSwizzle([UIView class], @selector(didMoveToWindow), @selector(tg_didMoveToWindow));
    BOOL s14 = TGSwizzle([UIBarButtonItem class], @selector(setTitle:), @selector(tg_setTitle:));
    BOOL s15 = TGSwizzle([UITabBarItem class], @selector(setTitle:), @selector(tg_setTitle:));
    BOOL s16 = TGSwizzleClass([UIAlertController class], @selector(alertControllerWithTitle:message:preferredStyle:),
                              @selector(tg_alertWithTitle:message:preferredStyle:));
    BOOL s17 = TGSwizzleClass([UIAlertAction class], @selector(actionWithTitle:style:handler:),
                              @selector(tg_actionWithTitle:style:handler:));
    BOOL s18 = TGSwizzle([UITextView class], @selector(setText:), @selector(tg_setText:));
    BOOL s19 = TGSwizzle([UITextView class], @selector(setAttributedText:), @selector(tg_setAttributedText:));

}

// 双保险：老式 __mod_init_func 路径（+load 已经兜过底，这里会直接返回）
__attribute__((constructor)) static void TGInitCtor(void) { TGChineseInit(); }
