// Tweak.xm - WeChatChangeTime

#import "WeChatHeaders.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString *const kWCChangeTimeEnabledKey = @"WCChangeTimeEnabled";

static BOOL WCChangeTime_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCChangeTimeEnabledKey];
}

#pragma mark - Associated Keys

static char kWCCT_OrigDateKey;
static char kWCCT_OrigShortKey;
static char kWCCT_OrigExpandedKey;
static char kWCCT_OrigClockKey;
static char kWCCT_CustomShortKey;
static char kWCCT_CustomExpandedKey;
static char kWCCT_LongPressGestureKey;
static BOOL kWCCT_IsSettingText = NO;

#pragma mark - Formatting

static NSString *WCChangeTime_weekday(NSInteger idx) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    });
    return (idx >= 1 && idx <= 7) ? names[idx] : @"";
}

static NSString *WCChangeTime_clockString(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"HH:mm";
    return [formatter stringFromDate:date];
}

static NSString *WCChangeTime_shortFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];
    NSString *clock = WCChangeTime_clockString(date);

    if ([calendar isDateInToday:date]) return clock;
    if ([calendar isDateInYesterday:date]) return [NSString stringWithFormat:@"昨天 %@", clock];

    NSDateComponents *diff = [calendar components:NSCalendarUnitDay
                                         fromDate:[calendar startOfDayForDate:date]
                                           toDate:[calendar startOfDayForDate:now]
                                          options:0];
    if (diff.day >= 2 && diff.day <= 6) {
        return [NSString stringWithFormat:@"%@ %@", WCChangeTime_weekday(target.weekday), clock];
    }

    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@", (long)target.month, (long)target.day, clock];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@", (long)target.year, (long)target.month, (long)target.day, clock];
}

static NSString *WCChangeTime_expandedFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];
    NSString *clock = WCChangeTime_clockString(date);
    NSString *weekday = WCChangeTime_weekday(target.weekday);
    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];

    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日%@%@", (long)target.month, (long)target.day, weekday, clock];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日%@%@", (long)target.year, (long)target.month, (long)target.day, weekday, clock];
}

static BOOL WCChangeTime_textLooksExpanded(NSString *text) {
    if (!text) return NO;
    BOOL hasMonthDay = [text containsString:@"月"] && [text containsString:@"日"];
    BOOL hasWeekday = [text containsString:@"星期"];
    return [text containsString:@"年"] || (hasMonthDay && hasWeekday);
}

#pragma mark - Text Helpers

static NSString *WCChangeTime_normalize(NSString *text) {
    if (!text) return nil;
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\u3000" withString:@" "];
    normalized = [normalized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([normalized containsString:@"  "]) {
        normalized = [normalized stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return normalized;
}

static NSString *WCChangeTime_compact(NSString *text) {
    NSString *normalized = WCChangeTime_normalize(text);
    if (!normalized) return nil;
    return [[normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
}

static BOOL WCChangeTime_looseEquals(NSString *lhs, NSString *rhs) {
    if (!lhs || !rhs) return NO;
    if ([lhs isEqualToString:rhs]) return YES;

    NSString *left = WCChangeTime_normalize(lhs);
    NSString *right = WCChangeTime_normalize(rhs);
    if ([left isEqualToString:right]) return YES;

    NSString *leftCompact = WCChangeTime_compact(lhs);
    NSString *rightCompact = WCChangeTime_compact(rhs);
    return leftCompact && rightCompact && [leftCompact isEqualToString:rightCompact];
}

static NSString *WCChangeTime_timeToken(NSString *text) {
    NSString *normalized = WCChangeTime_normalize(text);
    if (!normalized.length) return nil;

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2}:\\d{2})"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:normalized
                                                    options:0
                                                      range:NSMakeRange(0, normalized.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [normalized substringWithRange:[match rangeAtIndex:1]];
}

static BOOL WCChangeTime_isClockOnlyText(NSString *text) {
    NSString *normalized = WCChangeTime_normalize(text);
    if (!normalized.length) return NO;

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,2}:\\d{2}$"
                                                                           options:0
                                                                             error:nil];
    return [regex firstMatchInString:normalized options:0 range:NSMakeRange(0, normalized.length)] != nil;
}

#pragma mark - View Lookup

static UIView *WCChangeTime_findChatTimeCellView(UIView *view) {
    UIView *current = view;
    while (current) {
        if ([current isKindOfClass:objc_getClass("ChatTimeCellView")]) return current;
        current = current.superview;
    }
    return nil;
}

static UILabel *WCChangeTime_findTimeLabel(UIView *view) {
    if (!view) return nil;

    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:objc_getClass("MMUILabel")]) return (UILabel *)subview;
    }
    for (UIView *subview in view.subviews) {
        UILabel *found = WCChangeTime_findTimeLabel(subview);
        if (found) return found;
    }
    return nil;
}

static UIViewController *WCChangeTime_findVC(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
        responder = [responder nextResponder];
    }
    return nil;
}

#pragma mark - Parsing

static NSDate *WCChangeTime_parseTime(NSString *raw) {
    NSString *input = WCChangeTime_normalize(raw);
    if (!input.length) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    for (NSString *relative in @[@"昨天", @"今天", @"明天"]) {
        if ([input hasPrefix:relative]) {
            NSString *clock = [[input substringFromIndex:relative.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
            formatter.dateFormat = @"HH:mm";

            NSDate *time = [formatter dateFromString:clock];
            if (!time) return nil;

            NSInteger dayOffset = 0;
            if ([relative isEqualToString:@"昨天"]) dayOffset = -1;
            if ([relative isEqualToString:@"明天"]) dayOffset = 1;

            NSDate *targetDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:dayOffset toDate:now options:0];
            NSDateComponents *dayComp = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:targetDay];
            NSDateComponents *timeComp = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:time];
            dayComp.hour = timeComp.hour;
            dayComp.minute = timeComp.minute;
            return [calendar dateFromComponents:dayComp];
        }
    }

    NSRegularExpression *weekdayRegex = [NSRegularExpression regularExpressionWithPattern:@"星期[日一二三四五六天]"
                                                                                  options:0
                                                                                    error:nil];
    NSString *stripped = [weekdayRegex stringByReplacingMatchesInString:input
                                                                options:0
                                                                  range:NSMakeRange(0, input.length)
                                                           withTemplate:@""];
    stripped = WCChangeTime_normalize(stripped);

    if ([input hasPrefix:@"星期"]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"星期([日一二三四五六天])\\s*(\\d{1,2}):(\\d{2})"
                                                                               options:0
                                                                                 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:input options:0 range:NSMakeRange(0, input.length)];
        if (match && match.numberOfRanges == 4) {
            NSDictionary<NSString *, NSNumber *> *weekdayMap = @{
                @"日": @1,
                @"一": @2,
                @"二": @3,
                @"三": @4,
                @"四": @5,
                @"五": @6,
                @"六": @7,
                @"天": @1,
            };

            NSInteger targetWeekday = [weekdayMap[[input substringWithRange:[match rangeAtIndex:1]]] integerValue];
            NSInteger currentWeekday = [calendar component:NSCalendarUnitWeekday fromDate:now];
            NSInteger offset = targetWeekday - currentWeekday;
            if (offset > 0) offset -= 7;

            NSDate *targetDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:offset toDate:now options:0];
            NSDateComponents *dayComp = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:targetDay];
            dayComp.hour = [[input substringWithRange:[match rangeAtIndex:2]] integerValue];
            dayComp.minute = [[input substringWithRange:[match rangeAtIndex:3]] integerValue];
            return [calendar dateFromComponents:dayComp];
        }
    }

    NSArray<NSString *> *formats = @[
        @"yyyy-MM-dd HH:mm",
        @"yyyy/MM/dd HH:mm",
        @"yyyy.MM.dd HH:mm",
        @"yyyy年M月d日 HH:mm",
        @"yyyy年MM月dd日 HH:mm",
        @"yyyy年M月d日HH:mm",
        @"yyyy年MM月dd日HH:mm",
        @"MM-dd HH:mm",
        @"M-d HH:mm",
        @"MM/dd HH:mm",
        @"M/d HH:mm",
        @"M月d日 HH:mm",
        @"MM月dd日 HH:mm",
        @"M月d日HH:mm",
        @"MM月dd日HH:mm",
        @"HH:mm",
        @"H:mm",
    ];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *candidate in @[stripped ?: @"", WCChangeTime_compact(stripped) ?: @"", input, WCChangeTime_compact(input) ?: @""]) {
        if (candidate.length > 0 && ![candidates containsObject:candidate]) {
            [candidates addObject:candidate];
        }
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = [NSTimeZone localTimeZone];

    for (NSString *candidate in candidates) {
        for (NSString *format in formats) {
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:candidate];
            if (!date) continue;

            if ([format hasPrefix:@"H"]) {
                NSDateComponents *dayComp = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
                NSDateComponents *timeComp = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                dayComp.hour = timeComp.hour;
                dayComp.minute = timeComp.minute;
                return [calendar dateFromComponents:dayComp];
            }

            if ([format hasPrefix:@"M"]) {
                NSDateComponents *comp = [calendar components:(NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                comp.year = [calendar component:NSCalendarUnitYear fromDate:now];
                return [calendar dateFromComponents:comp];
            }

            return date;
        }
    }

    return nil;
}

#pragma mark - State

static void WCChangeTime_clear(UIView *cellView) {
    objc_setAssociatedObject(cellView, &kWCCT_OrigDateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_OrigShortKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_OrigExpandedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_OrigClockKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_CustomShortKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_CustomExpandedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void WCChangeTime_applyLabelText(UILabel *label, UIView *cellView, NSString *text) {
    if (!label || !text.length) return;

    kWCCT_IsSettingText = YES;
    label.text = text;
    if ([label respondsToSelector:@selector(setTextToCopy:)]) {
        ((MMUILabel *)label).textToCopy = text;
    }
    kWCCT_IsSettingText = NO;

    [label invalidateIntrinsicContentSize];
    [cellView setNeedsLayout];
}

static void WCChangeTime_restoreOriginal(UIView *cellView) {
    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    NSString *currentText = label.text ?: @"";
    NSString *origShort = objc_getAssociatedObject(cellView, &kWCCT_OrigShortKey);
    NSString *origExpanded = objc_getAssociatedObject(cellView, &kWCCT_OrigExpandedKey);

    NSString *restoreText = WCChangeTime_textLooksExpanded(currentText) ? (origExpanded ?: origShort) : (origShort ?: origExpanded);
    WCChangeTime_clear(cellView);

    if (restoreText.length > 0 && label) {
        WCChangeTime_applyLabelText(label, cellView, restoreText);
        return;
    }

    [cellView setNeedsLayout];
}

static NSString *WCChangeTime_resolve(UIView *cellView, NSString *incoming) {
    NSDate *origDate = objc_getAssociatedObject(cellView, &kWCCT_OrigDateKey);
    NSString *origShort = objc_getAssociatedObject(cellView, &kWCCT_OrigShortKey);
    NSString *origExpanded = objc_getAssociatedObject(cellView, &kWCCT_OrigExpandedKey);
    NSString *origClock = objc_getAssociatedObject(cellView, &kWCCT_OrigClockKey);
    NSString *customShort = objc_getAssociatedObject(cellView, &kWCCT_CustomShortKey);
    NSString *customExpanded = objc_getAssociatedObject(cellView, &kWCCT_CustomExpandedKey);
    if (!customShort || !customExpanded) return nil;

    if (WCChangeTime_looseEquals(incoming, customShort) || WCChangeTime_looseEquals(incoming, customExpanded)) {
        return nil;
    }

    if (origShort && WCChangeTime_looseEquals(incoming, origShort)) {
        return customShort;
    }
    if (origExpanded && WCChangeTime_looseEquals(incoming, origExpanded)) {
        return customExpanded;
    }

    NSDate *incomingDate = WCChangeTime_parseTime(incoming);
    if (origDate && incomingDate) {
        NSTimeInterval diff = [incomingDate timeIntervalSinceDate:origDate];
        if (diff < 0) diff = -diff;
        if (diff < 60.0) {
            return WCChangeTime_textLooksExpanded(incoming) ? customExpanded : customShort;
        }
    }

    NSString *incomingClock = WCChangeTime_timeToken(incoming);
    if (origClock && incomingClock && [incomingClock isEqualToString:origClock] && WCChangeTime_isClockOnlyText(incoming)) {
        return customShort;
    }

    WCChangeTime_clear(cellView);
    return nil;
}

#pragma mark - Editor

static void WCChangeTime_showEditor(UIView *cellView) {
    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    if (!label) return;

    UIViewController *vc = WCChangeTime_findVC(cellView);
    if (!vc) return;

    NSString *currentText = label.text ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WC-TIME"
                                                                  message:@"修改聊天时间显示\n\n支持输入格式：\n14:30\n昨天 14:30\n星期六 14:30\n3月29日 14:30\n3月29日星期六14:30\n2025-03-29 14:30"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"输入新时间";
        textField.text = currentText;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSDate *newDate = WCChangeTime_parseTime(alert.textFields.firstObject.text);
        if (!newDate) {
            UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"格式错误"
                                                                                message:@"无法解析，请使用支持的格式重试"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [errorAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:errorAlert animated:YES completion:nil];
            return;
        }

        NSDate *origDate = objc_getAssociatedObject(cellView, &kWCCT_OrigDateKey);
        NSString *origShort = objc_getAssociatedObject(cellView, &kWCCT_OrigShortKey);
        NSString *origExpanded = objc_getAssociatedObject(cellView, &kWCCT_OrigExpandedKey);
        NSString *origClock = objc_getAssociatedObject(cellView, &kWCCT_OrigClockKey);

        if (!origDate && !origShort && !origExpanded) {
            origDate = WCChangeTime_parseTime(currentText);

            BOOL expandedNow = WCChangeTime_textLooksExpanded(currentText);
            origShort = expandedNow ? nil : currentText;
            origExpanded = expandedNow ? currentText : nil;

            if (origDate) {
                if (!origShort) origShort = WCChangeTime_shortFormat(origDate);
                if (!origExpanded) origExpanded = WCChangeTime_expandedFormat(origDate);
            }

            origClock = WCChangeTime_timeToken(currentText);
            if (!origClock && origDate) {
                origClock = WCChangeTime_clockString(origDate);
            }
        }

        NSString *customShort = WCChangeTime_shortFormat(newDate);
        NSString *customExpanded = WCChangeTime_expandedFormat(newDate);

        objc_setAssociatedObject(cellView, &kWCCT_OrigDateKey, origDate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_OrigShortKey, origShort, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_OrigExpandedKey, origExpanded, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_OrigClockKey, origClock, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_CustomShortKey, customShort, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellView, &kWCCT_CustomExpandedKey, customExpanded, OBJC_ASSOCIATION_COPY_NONATOMIC);

        NSString *display = WCChangeTime_textLooksExpanded(currentText) ? customExpanded : customShort;
        WCChangeTime_applyLabelText(label, cellView, display);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"还原"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        WCChangeTime_restoreOriginal(cellView);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Gesture

static void WCChangeTime_longPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan || !WCChangeTime_enabled()) return;

    UIView *cellView = gesture.view;
    if (!cellView) return;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    WCChangeTime_showEditor(cellView);
}

#pragma mark - Hook ChatTimeCellView

%hook ChatTimeCellView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    if (objc_getAssociatedObject(self, &kWCCT_LongPressGestureKey)) return;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(wcct_lp:)];
    longPress.minimumPressDuration = 0.8;
    self.userInteractionEnabled = YES;

    for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            [gesture requireGestureRecognizerToFail:longPress];
        }
    }

    UILabel *label = WCChangeTime_findTimeLabel(self);
    if (label) {
        for (UIGestureRecognizer *gesture in label.gestureRecognizers) {
            if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                [gesture requireGestureRecognizerToFail:longPress];
            }
        }
    }

    [self addGestureRecognizer:longPress];
    objc_setAssociatedObject(self, &kWCCT_LongPressGestureKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)wcct_lp:(UILongPressGestureRecognizer *)gesture {
    WCChangeTime_longPress(gesture);
}

%end

#pragma mark - Hook MMUILabel

%hook MMUILabel

- (void)setText:(NSString *)text {
    if (kWCCT_IsSettingText) {
        %orig;
        return;
    }

    UIView *cellView = WCChangeTime_findChatTimeCellView(self);
    if (cellView) {
        NSString *replacement = WCChangeTime_resolve(cellView, text);
        if (replacement) {
            %orig(replacement);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) self.textToCopy = replacement;
            return;
        }
    }

    %orig;
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (kWCCT_IsSettingText) {
        %orig;
        return;
    }

    UIView *cellView = WCChangeTime_findChatTimeCellView(self);
    if (cellView) {
        NSString *replacement = WCChangeTime_resolve(cellView, attributedText.string ?: @"");
        if (replacement) {
            NSMutableAttributedString *mutableAttr = [[NSMutableAttributedString alloc] initWithString:replacement];
            if (attributedText.length > 0) {
                NSDictionary *attrs = [attributedText attributesAtIndex:0 effectiveRange:NULL];
                if (attrs) [mutableAttr setAttributes:attrs range:NSMakeRange(0, replacement.length)];
            }
            %orig(mutableAttr);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) self.textToCopy = replacement;
            return;
        }
    }

    %orig;
}

%end

#pragma mark - Register

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSClassFromString(@"WCPluginsMgr")) {
                [[objc_getClass("WCPluginsMgr") sharedInstance] registerSwitchWithTitle:@"WC-TIME" key:kWCChangeTimeEnabledKey];
            }
        });
    }
}
