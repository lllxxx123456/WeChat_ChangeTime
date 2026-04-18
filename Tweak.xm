// Tweak.xm - WeChatChangeTime

#import "WeChatHeaders.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString *const kWCChangeTimeEnabledKey = @"WCChangeTimeEnabled";

static char kWCCT_CustomDateKey;
static char kWCCT_CustomDateMapKey;
static char kWCCT_LongPressGestureKey;

static BOOL WCChangeTime_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCChangeTimeEnabledKey];
}

#pragma mark - Format

static NSString *WCChangeTime_weekday(NSInteger idx) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    });
    return (idx >= 1 && idx <= 7) ? names[idx] : @"";
}

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
    if (!normalized.length) return nil;
    return [[normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
}

static BOOL WCChangeTime_hasWhitespace(NSString *text) {
    NSString *normalized = WCChangeTime_normalize(text);
    if (!normalized.length) return NO;
    return [normalized rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound;
}

static BOOL WCChangeTime_textLooksExpanded(NSString *text) {
    if (!text.length) return NO;
    BOOL hasMonthDay = [text containsString:@"月"] && [text containsString:@"日"];
    BOOL hasWeekday = [text containsString:@"星期"];
    return [text containsString:@"年"] || (hasMonthDay && hasWeekday);
}

static NSString *WCChangeTime_clockString(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"HH:mm";
    return [formatter stringFromDate:date];
}

static NSString *WCChangeTime_shortFormat(NSDate *date, BOOL compactStyle) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];
    NSString *clock = WCChangeTime_clockString(date);
    NSString *separator = compactStyle ? @"" : @" ";

    if ([calendar isDateInToday:date]) return clock;
    if ([calendar isDateInYesterday:date]) return [NSString stringWithFormat:@"昨天%@%@", separator, clock];

    NSDateComponents *diff = [calendar components:NSCalendarUnitDay
                                         fromDate:[calendar startOfDayForDate:date]
                                           toDate:[calendar startOfDayForDate:now]
                                          options:0];
    if (diff.day >= 2 && diff.day <= 6) {
        return [NSString stringWithFormat:@"%@%@%@", WCChangeTime_weekday(target.weekday), separator, clock];
    }

    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日%@%@", (long)target.month, (long)target.day, separator, clock];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日%@%@", (long)target.year, (long)target.month, (long)target.day, separator, clock];
}

static NSString *WCChangeTime_expandedFormat(NSDate *date, BOOL compactStyle) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];
    NSString *clock = WCChangeTime_clockString(date);
    NSString *weekday = WCChangeTime_weekday(target.weekday);

    if (compactStyle) {
        NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
        if (target.year == currentYear) {
            return [NSString stringWithFormat:@"%ld月%ld日%@%@", (long)target.month, (long)target.day, weekday, clock];
        }
        return [NSString stringWithFormat:@"%ld年%ld月%ld日%@%@", (long)target.year, (long)target.month, (long)target.day, weekday, clock];
    }

    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@ %@", (long)target.month, (long)target.day, weekday, clock];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@ %@", (long)target.year, (long)target.month, (long)target.day, weekday, clock];
}

static NSString *WCChangeTime_formatLikeOriginal(NSDate *date, NSString *originalText) {
    BOOL compactStyle = !WCChangeTime_hasWhitespace(originalText);
    return WCChangeTime_textLooksExpanded(originalText) ? WCChangeTime_expandedFormat(date, compactStyle) : WCChangeTime_shortFormat(date, compactStyle);
}

#pragma mark - View Lookup

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

#pragma mark - Parse

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

#pragma mark - ViewModel State

static NSString *WCChangeTime_keyForViewModel(ChatTimeViewModel *viewModel) {
    if (!viewModel) return nil;

    NSTimeInterval timestamp = viewModel.showingTime;
    if (timestamp <= 0.0) timestamp = viewModel.createTime;
    if (timestamp <= 0.0) return nil;

    return [NSString stringWithFormat:@"show:%.6f|create:%.6f|model:%llu|split:%llu",
            viewModel.showingTime,
            viewModel.createTime,
            (unsigned long long)viewModel.modelType,
            (unsigned long long)viewModel.splitPosition];
}

static NSMutableDictionary<NSString *, NSDate *> *WCChangeTime_mapForController(UIViewController *vc, BOOL createIfNeeded) {
    if (!vc) return nil;

    NSMutableDictionary<NSString *, NSDate *> *map = objc_getAssociatedObject(vc, &kWCCT_CustomDateMapKey);
    if (!map && createIfNeeded) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(vc, &kWCCT_CustomDateMapKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static NSDate *WCChangeTime_customDateForViewModel(ChatTimeViewModel *viewModel) {
    if (!viewModel) return nil;

    NSDate *date = objc_getAssociatedObject(viewModel, &kWCCT_CustomDateKey);
    if (date) return date;

    UIView *cellView = [viewModel.cellView isKindOfClass:[UIView class]] ? (UIView *)viewModel.cellView : nil;
    UIViewController *vc = WCChangeTime_findVC(cellView);
    NSString *key = WCChangeTime_keyForViewModel(viewModel);
    if (!vc || !key.length) return nil;

    date = WCChangeTime_mapForController(vc, NO)[key];
    if (date) {
        objc_setAssociatedObject(viewModel, &kWCCT_CustomDateKey, date, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return date;
}

static void WCChangeTime_storeCustomDate(ChatTimeViewModel *viewModel, UIViewController *vc, NSDate *date) {
    if (!viewModel) return;

    objc_setAssociatedObject(viewModel, &kWCCT_CustomDateKey, date, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *key = WCChangeTime_keyForViewModel(viewModel);
    if (!vc || !key.length) return;

    NSMutableDictionary<NSString *, NSDate *> *map = WCChangeTime_mapForController(vc, date != nil);
    if (!map) return;

    if (date) {
        map[key] = date;
    } else {
        [map removeObjectForKey:key];
    }
}

static NSString *WCChangeTime_replacementText(ChatTimeViewModel *viewModel, NSString *originalText) {
    if (!WCChangeTime_enabled()) return nil;

    NSDate *customDate = WCChangeTime_customDateForViewModel(viewModel);
    if (!customDate) return nil;

    NSString *baseText = originalText;
    if (!baseText.length) {
        UIView *cellView = [viewModel.cellView isKindOfClass:[UIView class]] ? (UIView *)viewModel.cellView : nil;
        UILabel *label = WCChangeTime_findTimeLabel(cellView);
        baseText = label.text ?: @"";
    }
    if (!baseText.length) return nil;
    return WCChangeTime_formatLikeOriginal(customDate, baseText);
}

#pragma mark - UI Refresh

static void WCChangeTime_applyLabelText(UILabel *label, NSString *text) {
    if (!label || !text.length) return;

    label.text = text;
    if ([label respondsToSelector:@selector(setTextToCopy:)]) {
        ((MMUILabel *)label).textToCopy = text;
    }
    [label invalidateIntrinsicContentSize];
}

static void WCChangeTime_refreshTimeCell(ChatTimeCellView *cellView) {
    if (!cellView || !WCChangeTime_enabled()) return;

    ChatTimeViewModel *viewModel = cellView.viewModel;
    if (!viewModel) return;

    NSString *displayText = WCChangeTime_replacementText(viewModel, nil);
    if (!displayText.length) return;

    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    if (!label) return;

    WCChangeTime_applyLabelText(label, displayText);
}

#pragma mark - Editor

static void WCChangeTime_showEditor(ChatTimeCellView *cellView) {
    if (!cellView) return;

    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    ChatTimeViewModel *viewModel = cellView.viewModel;
    if (!label || !viewModel) return;

    UIViewController *vc = WCChangeTime_findVC(cellView);
    if (!vc) return;

    NSString *currentText = label.text.length ? label.text : (viewModel.timeText ?: @"");

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

        WCChangeTime_storeCustomDate(viewModel, vc, newDate);
        [viewModel updateLayouts];
        [cellView setNeedsLayout];
        [cellView layoutIfNeeded];
        WCChangeTime_refreshTimeCell(cellView);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"还原"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        WCChangeTime_storeCustomDate(viewModel, vc, nil);
        [viewModel updateLayouts];
        [cellView setNeedsLayout];
        [cellView layoutIfNeeded];
        WCChangeTime_applyLabelText(label, viewModel.timeText ?: @"");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Gesture

static void WCChangeTime_longPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan || !WCChangeTime_enabled()) return;

    ChatTimeCellView *cellView = [gesture.view isKindOfClass:objc_getClass("ChatTimeCellView")] ? (ChatTimeCellView *)gesture.view : nil;
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
    if (objc_getAssociatedObject(self, &kWCCT_LongPressGestureKey)) {
        WCChangeTime_refreshTimeCell(self);
        return;
    }

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
    WCChangeTime_refreshTimeCell(self);
}

- (void)setViewModel:(id)viewModel {
    %orig;
    WCChangeTime_refreshTimeCell(self);
}

- (void)layoutInternal {
    %orig;
    WCChangeTime_refreshTimeCell(self);
}

- (void)onClickTimeLabel {
    %orig;
    WCChangeTime_refreshTimeCell(self);
}

%new
- (void)wcct_lp:(UILongPressGestureRecognizer *)gesture {
    WCChangeTime_longPress(gesture);
}

%end

#pragma mark - Hook ChatTimeViewModel

%hook ChatTimeViewModel

- (NSString *)timeText {
    NSString *originalText = %orig;
    NSString *replacement = WCChangeTime_replacementText(self, originalText);
    return replacement ?: originalText;
}

- (double)labelWidth {
    double originalWidth = %orig;
    NSString *displayText = WCChangeTime_replacementText(self, nil);
    if (!displayText.length) return originalWidth;

    UIView *cellView = [self.cellView isKindOfClass:[UIView class]] ? (UIView *)self.cellView : nil;
    UILabel *label = WCChangeTime_findTimeLabel(cellView);
    UIFont *font = label.font ?: [UIFont systemFontOfSize:12.0];

    CGRect rect = [displayText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                         attributes:@{NSFontAttributeName: font}
                                            context:nil];
    return ceil(rect.size.width);
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
