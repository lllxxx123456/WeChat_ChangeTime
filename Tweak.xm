// Tweak.xm — WeChatChangeTime

#import "WeChatHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *const kWCChangeTimeEnabledKey = @"WCChangeTimeEnabled";
static BOOL WCChangeTime_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCChangeTimeEnabledKey];
}

#pragma mark - 关联对象 Key

static char kWCCT_OrigDateKey;
static char kWCCT_CustomShortKey;
static char kWCCT_CustomExpandedKey;
static char kWCCT_LongPressGestureKey;
static BOOL kWCCT_IsSettingText = NO;

#pragma mark - 星期数组

static NSString *WCChangeTime_weekday(NSInteger idx) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    });
    return (idx >= 1 && idx <= 7) ? names[idx] : @"";
}

#pragma mark - 时间格式化

static NSString *WCChangeTime_shortFormat(NSDate *date) {
    if (!date) return nil;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *t = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitWeekday) fromDate:date];
    NSDateFormatter *tf = [[NSDateFormatter alloc] init];
    tf.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    tf.dateFormat = @"HH:mm";
    NSString *ts = [tf stringFromDate:date];
    if ([cal isDateInToday:date]) return ts;
    if ([cal isDateInYesterday:date]) return [NSString stringWithFormat:@"昨天 %@", ts];
    NSDateComponents *dc = [cal components:NSCalendarUnitDay fromDate:[cal startOfDayForDate:date] toDate:[cal startOfDayForDate:now] options:0];
    if (dc.day >= 2 && dc.day <= 6) return [NSString stringWithFormat:@"%@ %@", WCChangeTime_weekday(t.weekday), ts];
    NSInteger curY = [cal component:NSCalendarUnitYear fromDate:now];
    if (t.year == curY) return [NSString stringWithFormat:@"%ld月%ld日 %@", (long)t.month, (long)t.day, ts];
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@", (long)t.year, (long)t.month, (long)t.day, ts];
}

static NSString *WCChangeTime_expandedFormat(NSDate *date) {
    if (!date) return nil;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *t = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitWeekday) fromDate:date];
    NSDateFormatter *tf = [[NSDateFormatter alloc] init];
    tf.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    tf.dateFormat = @"HH:mm";
    NSString *ts = [tf stringFromDate:date];
    NSString *wd = WCChangeTime_weekday(t.weekday);
    NSInteger curY = [cal component:NSCalendarUnitYear fromDate:now];
    if (t.year == curY) return [NSString stringWithFormat:@"%ld月%ld日 %@ %@", (long)t.month, (long)t.day, wd, ts];
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@ %@", (long)t.year, (long)t.month, (long)t.day, wd, ts];
}

#pragma mark - 判断文本格式

static BOOL WCChangeTime_textLooksExpanded(NSString *text) {
    if (!text) return NO;
    BOOL hasMonthDay = [text containsString:@"月"] && [text containsString:@"日"];
    BOOL hasWeekday = [text containsString:@"星期"];
    return [text containsString:@"年"] || (hasMonthDay && hasWeekday);
}

#pragma mark - 向上遍历查找 ChatTimeCellView

static UIView *WCChangeTime_findChatTimeCellView(UIView *view) {
    UIView *cur = view;
    while (cur) {
        if ([cur isKindOfClass:objc_getClass("ChatTimeCellView")]) return cur;
        cur = cur.superview;
    }
    return nil;
}

#pragma mark - 查找 MMUILabel

static UILabel *WCChangeTime_findTimeLabel(UIView *view) {
    if (!view) return nil;
    for (UIView *sv in view.subviews) {
        if ([sv isKindOfClass:objc_getClass("MMUILabel")]) return (UILabel *)sv;
    }
    for (UIView *sv in view.subviews) {
        UILabel *f = WCChangeTime_findTimeLabel(sv);
        if (f) return f;
    }
    return nil;
}

#pragma mark - 查找 ViewController

static UIViewController *WCChangeTime_findVC(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = [r nextResponder];
    }
    return nil;
}

#pragma mark - 时间解析（用户输入 & 微信原始文本）

static NSString *WCChangeTime_normalize(NSString *s) {
    if (!s) return nil;
    s = [s stringByReplacingOccurrencesOfString:@"\u3000" withString:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s containsString:@"  "]) s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return s;
}

static NSDate *WCChangeTime_parseTime(NSString *raw) {
    NSString *input = WCChangeTime_normalize(raw);
    if (!input || input.length == 0) return nil;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    // "昨天/今天/明天 HH:mm"
    for (NSString *rel in @[@"昨天", @"今天", @"明天"]) {
        if ([input hasPrefix:rel]) {
            NSString *tp = [[input substringFromIndex:rel.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"]; f.dateFormat = @"HH:mm";
            NSDate *t = [f dateFromString:tp]; if (!t) return nil;
            NSInteger off = [rel isEqualToString:@"昨天"] ? -1 : [rel isEqualToString:@"明天"] ? 1 : 0;
            NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:off toDate:now options:0];
            NSDateComponents *dc = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:day];
            NSDateComponents *tc = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:t];
            dc.hour = tc.hour; dc.minute = tc.minute;
            return [cal dateFromComponents:dc];
        }
    }

    // 剥离"星期X"
    NSRegularExpression *wkRe = [NSRegularExpression regularExpressionWithPattern:@"星期[日一二三四五六天]" options:0 error:nil];
    NSString *stripped = [wkRe stringByReplacingMatchesInString:input options:0 range:NSMakeRange(0, input.length) withTemplate:@""];
    stripped = WCChangeTime_normalize(stripped);

    // "星期X HH:mm" 折叠格式
    if ([input hasPrefix:@"星期"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"星期([日一二三四五六天])\\s*(\\d{1,2}):(\\d{2})" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:input options:0 range:NSMakeRange(0, input.length)];
        if (m && m.numberOfRanges == 4) {
            NSDictionary *wkMap = @{@"日":@1,@"一":@2,@"二":@3,@"三":@4,@"四":@5,@"五":@6,@"六":@7,@"天":@1};
            NSInteger tw = [wkMap[[input substringWithRange:[m rangeAtIndex:1]]] integerValue];
            NSInteger cw = [cal component:NSCalendarUnitWeekday fromDate:now];
            NSInteger off = tw - cw; if (off > 0) off -= 7;
            NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:off toDate:now options:0];
            NSDateComponents *dc = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:day];
            dc.hour = [[input substringWithRange:[m rangeAtIndex:2]] integerValue];
            dc.minute = [[input substringWithRange:[m rangeAtIndex:3]] integerValue];
            return [cal dateFromComponents:dc];
        }
    }

    // 常规格式
    NSArray *fmts = @[@"yyyy-MM-dd HH:mm",@"yyyy/MM/dd HH:mm",@"yyyy.MM.dd HH:mm",
                      @"yyyy年M月d日 HH:mm",@"yyyy年MM月dd日 HH:mm",
                      @"MM-dd HH:mm",@"M-d HH:mm",@"MM/dd HH:mm",@"M/d HH:mm",
                      @"M月d日 HH:mm",@"MM月dd日 HH:mm",@"HH:mm",@"H:mm"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    for (NSString *cand in @[stripped ?: @"", input]) {
        if (cand.length == 0) continue;
        for (NSString *f in fmts) {
            fmt.dateFormat = f;
            NSDate *d = [fmt dateFromString:cand]; if (!d) continue;
            if ([f hasPrefix:@"H"]) {
                NSDateComponents *dc = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:now];
                NSDateComponents *tc = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:d];
                dc.hour = tc.hour; dc.minute = tc.minute;
                return [cal dateFromComponents:dc];
            }
            if ([f hasPrefix:@"M"]) {
                NSDateComponents *c = [cal components:(NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:d];
                c.year = [cal component:NSCalendarUnitYear fromDate:now];
                return [cal dateFromComponents:c];
            }
            return d;
        }
    }
    return nil;
}

#pragma mark - 清除 / 解析替换

static void WCChangeTime_clear(UIView *v) {
    objc_setAssociatedObject(v, &kWCCT_OrigDateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kWCCT_CustomShortKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(v, &kWCCT_CustomExpandedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSString *WCChangeTime_resolve(UIView *cellView, NSString *incoming) {
    NSDate *origDate = objc_getAssociatedObject(cellView, &kWCCT_OrigDateKey);
    NSString *cShort = objc_getAssociatedObject(cellView, &kWCCT_CustomShortKey);
    NSString *cExpanded = objc_getAssociatedObject(cellView, &kWCCT_CustomExpandedKey);
    if (!origDate || !cShort || !cExpanded) return nil;

    // 已经是自定义文本 → 跳过
    if ([incoming isEqualToString:cShort] || [incoming isEqualToString:cExpanded]) return nil;

    // 解析传入文本日期，和原始日期比对（±60秒 = 同一条消息）
    NSDate *inDate = WCChangeTime_parseTime(incoming);
    if (inDate && fabs([inDate timeIntervalSinceDate:origDate]) < 60) {
        return WCChangeTime_textLooksExpanded(incoming) ? cExpanded : cShort;
    }

    // 不匹配 → cell 复用 → 清除
    WCChangeTime_clear(cellView);
    return nil;
}

#pragma mark - 弹窗编辑

static void WCChangeTime_showEditor(UIView *cellView) {
    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    if (!label) return;
    UIViewController *vc = WCChangeTime_findVC(cellView);
    if (!vc) return;
    NSString *curText = label.text ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WC-TIME"
                                                                  message:@"修改聊天时间显示\n\n支持输入格式：\n14:30\n昨天 14:30\n星期六 14:30\n3月29日 14:30\n2025-03-29 14:30"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"输入新时间";
        tf.text = curText;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSDate *newDate = WCChangeTime_parseTime(alert.textFields.firstObject.text);
        if (!newDate) {
            UIAlertController *e = [UIAlertController alertControllerWithTitle:@"格式错误"
                                                                      message:@"无法解析，请使用支持的格式"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [e addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:e animated:YES completion:nil];
            return;
        }
        NSDate *origDate = WCChangeTime_parseTime(curText) ?: [NSDate date];
        objc_setAssociatedObject(cellView, &kWCCT_OrigDateKey, origDate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_CustomShortKey, WCChangeTime_shortFormat(newDate), OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_CustomExpandedKey, WCChangeTime_expandedFormat(newDate), OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSString *display = WCChangeTime_textLooksExpanded(curText) ? WCChangeTime_expandedFormat(newDate) : WCChangeTime_shortFormat(newDate);
        kWCCT_IsSettingText = YES;
        label.text = display;
        if ([label respondsToSelector:@selector(setTextToCopy:)]) ((MMUILabel *)label).textToCopy = display;
        kWCCT_IsSettingText = NO;
        [label invalidateIntrinsicContentSize];
        [cellView setNeedsLayout];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        WCChangeTime_clear(cellView);
        [cellView setNeedsLayout];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 长按回调

static void WCChangeTime_longPress(UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan || !WCChangeTime_enabled()) return;
    UIView *v = g.view; if (!v) return;
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    WCChangeTime_showEditor(v);
}

#pragma mark - Hook ChatTimeCellView

%hook ChatTimeCellView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    if (objc_getAssociatedObject(self, &kWCCT_LongPressGestureKey)) return;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(wcct_lp:)];
    lp.minimumPressDuration = 0.8;
    self.userInteractionEnabled = YES;

    for (UIGestureRecognizer *gr in self.gestureRecognizers)
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) [gr requireGestureRecognizerToFail:lp];
    UILabel *lb = WCChangeTime_findTimeLabel(self);
    if (lb) for (UIGestureRecognizer *gr in lb.gestureRecognizers)
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) [gr requireGestureRecognizerToFail:lp];

    [self addGestureRecognizer:lp];
    objc_setAssociatedObject(self, &kWCCT_LongPressGestureKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)wcct_lp:(UILongPressGestureRecognizer *)g { WCChangeTime_longPress(g); }

%end

#pragma mark - Hook MMUILabel

%hook MMUILabel

- (void)setText:(NSString *)text {
    if (kWCCT_IsSettingText) { %orig; return; }
    UIView *cell = WCChangeTime_findChatTimeCellView(self);
    if (cell) {
        NSString *r = WCChangeTime_resolve(cell, text);
        if (r) {
            %orig(r);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) self.textToCopy = r;
            return;
        }
    }
    %orig;
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (kWCCT_IsSettingText) { %orig; return; }
    UIView *cell = WCChangeTime_findChatTimeCellView(self);
    if (cell) {
        NSString *r = WCChangeTime_resolve(cell, attributedText.string ?: @"");
        if (r) {
            NSMutableAttributedString *ma = [[NSMutableAttributedString alloc] initWithString:r];
            if (attributedText.length > 0) {
                NSDictionary *a = [attributedText attributesAtIndex:0 effectiveRange:NULL];
                if (a) [ma setAttributes:a range:NSMakeRange(0, r.length)];
            }
            %orig(ma);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) self.textToCopy = r;
            return;
        }
    }
    %orig;
}

%end

#pragma mark - 注册插件

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSClassFromString(@"WCPluginsMgr"))
                [[objc_getClass("WCPluginsMgr") sharedInstance] registerSwitchWithTitle:@"WC-TIME" key:kWCChangeTimeEnabledKey];
        });
    }
}
