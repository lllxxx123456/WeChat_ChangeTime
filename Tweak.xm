// Tweak.xm
// WeChatChangeTime - 长按聊天时间行修改显示时间
//
// 功能：
//   1) 长按 ChatTimeCellView 弹出时间编辑弹窗
//   2) 支持折叠/展开两种格式，自动跟随微信单击切换
//   3) 通过 WCPluginsMgr 注册开关（默认关闭）

#import "WeChatHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *const kWCChangeTimeEnabledKey = @"WCChangeTimeEnabled";

static BOOL WCChangeTime_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCChangeTimeEnabledKey];
}

#pragma mark - 关联对象 Key

static char kWCCT_OrigDateKey;           // 修改前的原始 NSDate
static char kWCCT_OrigShortKey;          // 修改前的原始折叠文本
static char kWCCT_OrigExpandedKey;       // 修改前的原始展开文本
static char kWCCT_CustomShortKey;        // 修改后的折叠文本
static char kWCCT_CustomExpandedKey;     // 修改后的展开文本
static char kWCCT_LongPressGestureKey;   // 长按手势引用

static BOOL kWCCT_IsSettingText = NO;    // 重入保护

#pragma mark - 星期数组

static NSArray<NSString *> *WCChangeTime_weekdayNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    });
    return names;
}

#pragma mark - 时间格式化：折叠

static NSString *WCChangeTime_shortFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];

    NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
    timeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    timeFmt.dateFormat = @"HH:mm";
    NSString *timeStr = [timeFmt stringFromDate:date];

    if ([calendar isDateInToday:date]) {
        return timeStr;
    }
    if ([calendar isDateInYesterday:date]) {
        return [NSString stringWithFormat:@"昨天 %@", timeStr];
    }

    NSDateComponents *diffComp = [calendar components:NSCalendarUnitDay fromDate:[calendar startOfDayForDate:date] toDate:[calendar startOfDayForDate:now] options:0];
    if (diffComp.day >= 2 && diffComp.day <= 6) {
        NSString *weekday = WCChangeTime_weekdayNames()[target.weekday];
        return [NSString stringWithFormat:@"%@ %@", weekday, timeStr];
    }

    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@", (long)target.month, (long)target.day, timeStr];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@", (long)target.year, (long)target.month, (long)target.day, timeStr];
}

#pragma mark - 时间格式化：展开

static NSString *WCChangeTime_expandedFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    NSDateComponents *target = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:date];

    NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
    timeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    timeFmt.dateFormat = @"HH:mm";
    NSString *timeStr = [timeFmt stringFromDate:date];

    NSString *weekday = WCChangeTime_weekdayNames()[target.weekday];
    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];

    if (target.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@ %@", (long)target.month, (long)target.day, weekday, timeStr];
    }
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@ %@", (long)target.year, (long)target.month, (long)target.day, weekday, timeStr];
}

#pragma mark - 判断文本是展开格式还是折叠格式

static BOOL WCChangeTime_textLooksExpanded(NSString *text) {
    if (!text) return NO;
    // 展开格式特征：
    //   "M月d日 星期X HH:mm"（含"月""日""星期"）
    //   "yyyy年M月d日 星期X HH:mm"（含"年"）
    BOOL hasYear = [text containsString:@"年"];
    BOOL hasMonthDay = [text containsString:@"月"] && [text containsString:@"日"];
    BOOL hasWeekday = [text containsString:@"星期"];
    return hasYear || (hasMonthDay && hasWeekday);
}

#pragma mark - 查找 MMUILabel

static UILabel *WCChangeTime_findTimeLabel(UIView *view) {
    if (!view) return nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:objc_getClass("MMUILabel")]) {
            return (UILabel *)subview;
        }
    }
    for (UIView *subview in view.subviews) {
        UILabel *found = WCChangeTime_findTimeLabel(subview);
        if (found) return found;
    }
    return nil;
}

#pragma mark - 查找父视图控制器

static UIViewController *WCChangeTime_findViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

#pragma mark - 输入时间解析

static NSString *WCChangeTime_normalizeInput(NSString *input) {
    if (!input) return nil;
    // 全角空格 → 半角
    NSString *s = [input stringByReplacingOccurrencesOfString:@"\u3000" withString:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 多个空格合一
    while ([s containsString:@"  "]) {
        s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return s;
}

// 从文本中剥离 "星期X" 子串（X ∈ 日/一/二/三/四/五/六/天）
static NSString *WCChangeTime_stripWeekday(NSString *s) {
    if (!s) return s;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"星期[日一二三四五六天]"
                                                                        options:0
                                                                          error:nil];
    NSString *out = [re stringByReplacingMatchesInString:s
                                                 options:0
                                                   range:NSMakeRange(0, s.length)
                                            withTemplate:@""];
    return WCChangeTime_normalizeInput(out);
}

static NSDate *WCChangeTime_parseInputTime(NSString *rawInput) {
    NSString *input = WCChangeTime_normalizeInput(rawInput);
    if (!input || input.length == 0) return nil;

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    // 1) 处理 "昨天/今天/明天 HH:mm"
    NSArray<NSString *> *relativeDays = @[@"昨天", @"今天", @"明天"];
    for (NSString *rel in relativeDays) {
        if ([input hasPrefix:rel]) {
            NSString *timePart = [[input substringFromIndex:rel.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSDateFormatter *tf = [[NSDateFormatter alloc] init];
            tf.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
            tf.dateFormat = @"HH:mm";
            NSDate *t = [tf dateFromString:timePart];
            if (!t) return nil;
            NSInteger offset = 0;
            if ([rel isEqualToString:@"昨天"]) offset = -1;
            else if ([rel isEqualToString:@"明天"]) offset = 1;
            NSDate *targetDay = [cal dateByAddingUnit:NSCalendarUnitDay value:offset toDate:now options:0];
            NSDateComponents *dayComp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:targetDay];
            NSDateComponents *timeComp = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:t];
            dayComp.hour = timeComp.hour;
            dayComp.minute = timeComp.minute;
            return [cal dateFromComponents:dayComp];
        }
    }

    // 2) 剥离"星期X"后再尝试解析（兼容展开格式）
    NSString *stripped = WCChangeTime_stripWeekday(input);

    // 3) 如果剥离后是纯 "星期X HH:mm"，stripped 就只剩时间
    //    需单独识别输入原本以"星期"开头的折叠格式 → 找本周对应日期
    if ([input hasPrefix:@"星期"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"星期([日一二三四五六天])\\s*(\\d{1,2}):(\\d{2})"
                                                                            options:0
                                                                              error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:input options:0 range:NSMakeRange(0, input.length)];
        if (m && m.numberOfRanges == 4) {
            NSString *wk = [input substringWithRange:[m rangeAtIndex:1]];
            NSString *hh = [input substringWithRange:[m rangeAtIndex:2]];
            NSString *mm = [input substringWithRange:[m rangeAtIndex:3]];
            NSDictionary<NSString *, NSNumber *> *wkMap = @{@"日": @1, @"一": @2, @"二": @3, @"三": @4, @"四": @5, @"五": @6, @"六": @7, @"天": @1};
            NSInteger targetWeekday = wkMap[wk].integerValue;
            NSInteger todayWeekday = [cal component:NSCalendarUnitWeekday fromDate:now];
            NSInteger offset = targetWeekday - todayWeekday;
            if (offset > 0) offset -= 7; // 往过去回退
            NSDate *target = [cal dateByAddingUnit:NSCalendarUnitDay value:offset toDate:now options:0];
            NSDateComponents *dayComp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:target];
            dayComp.hour = hh.integerValue;
            dayComp.minute = mm.integerValue;
            return [cal dateFromComponents:dayComp];
        }
    }

    // 4) 常规格式尝试
    NSArray<NSString *> *formats = @[
        @"yyyy-MM-dd HH:mm",
        @"yyyy/MM/dd HH:mm",
        @"yyyy.MM.dd HH:mm",
        @"yyyy年M月d日 HH:mm",
        @"yyyy年MM月dd日 HH:mm",
        @"MM-dd HH:mm",
        @"M-d HH:mm",
        @"MM/dd HH:mm",
        @"M/d HH:mm",
        @"M月d日 HH:mm",
        @"MM月dd日 HH:mm",
        @"HH:mm",
        @"H:mm",
    ];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.timeZone = [NSTimeZone localTimeZone];

    NSArray<NSString *> *candidates = @[stripped, input];
    for (NSString *cand in candidates) {
        if (!cand || cand.length == 0) continue;
        for (NSString *format in formats) {
            fmt.dateFormat = format;
            NSDate *date = [fmt dateFromString:cand];
            if (!date) continue;

            // 只输入时间：使用今天日期
            if ([format hasPrefix:@"H"]) {
                NSDateComponents *todayComp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
                NSDateComponents *timeComp = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                todayComp.hour = timeComp.hour;
                todayComp.minute = timeComp.minute;
                return [cal dateFromComponents:todayComp];
            }
            // 无年份：使用今年
            if ([format hasPrefix:@"M"]) {
                NSInteger currentYear = [cal component:NSCalendarUnitYear fromDate:now];
                NSDateComponents *comp = [cal components:(NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                comp.year = currentYear;
                return [cal dateFromComponents:comp];
            }
            return date;
        }
    }
    return nil;
}

#pragma mark - 应用自定义时间到 Label

static void WCChangeTime_applyToLabel(UILabel *label, UIView *timeCellView, NSString *displayText) {
    if (!label || !displayText) return;
    kWCCT_IsSettingText = YES;
    label.text = displayText;
    if ([label respondsToSelector:@selector(setTextToCopy:)]) {
        ((MMUILabel *)label).textToCopy = displayText;
    }
    kWCCT_IsSettingText = NO;
    // 让父视图重新 layout（不要手动改 frame，避免位置偏移）
    [label invalidateIntrinsicContentSize];
    [timeCellView setNeedsLayout];
}

#pragma mark - 清除自定义数据

static void WCChangeTime_clearCustomData(UIView *cellView) {
    objc_setAssociatedObject(cellView, &kWCCT_OrigDateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_OrigShortKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_OrigExpandedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_CustomShortKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellView, &kWCCT_CustomExpandedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

#pragma mark - 弹出编辑弹窗

static void WCChangeTime_showEditor(UIView *timeCellView) {
    UILabel *label = WCChangeTime_findTimeLabel(timeCellView);
    if (!label) return;

    UIViewController *vc = WCChangeTime_findViewController(timeCellView);
    if (!vc) return;

    NSString *currentText = label.text ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WC-TIME"
                                                                  message:@"修改聊天时间显示\n\n支持输入格式：\n02:30\n昨天 02:30\n星期五 02:30\n6月28日 02:30\n6月28日 星期五 02:30\n2024-06-28 02:30"
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"输入新时间";
        textField.text = currentText;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.keyboardType = UIKeyboardTypeDefault;
    }];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *inputText = alert.textFields.firstObject.text;
        NSDate *newDate = WCChangeTime_parseInputTime(inputText);

        if (!newDate) {
            UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"格式错误"
                                                                             message:[NSString stringWithFormat:@"无法解析：%@\n\n请使用支持的格式重试", inputText ?: @""]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [errAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:errAlert animated:YES completion:nil];
            return;
        }

        // 计算原始时间的短/展开格式（用于后续 hook 匹配）
        NSDate *origDate = WCChangeTime_parseInputTime(currentText);
        NSString *origShort = origDate ? WCChangeTime_shortFormat(origDate) : currentText;
        NSString *origExpanded = origDate ? WCChangeTime_expandedFormat(origDate) : nil;

        NSString *customShort = WCChangeTime_shortFormat(newDate);
        NSString *customExpanded = WCChangeTime_expandedFormat(newDate);

        objc_setAssociatedObject(timeCellView, &kWCCT_OrigDateKey, origDate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_OrigShortKey, origShort, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_OrigExpandedKey, origExpanded, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_CustomShortKey, customShort, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_CustomExpandedKey, customExpanded, OBJC_ASSOCIATION_COPY_NONATOMIC);

        // 根据当前显示状态决定用哪个
        BOOL expandedNow = WCChangeTime_textLooksExpanded(currentText);
        NSString *displayText = expandedNow ? customExpanded : customShort;
        WCChangeTime_applyToLabel(label, timeCellView, displayText);
    }];

    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        WCChangeTime_clearCustomData(timeCellView);
        [timeCellView setNeedsLayout];
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:confirmAction];
    [alert addAction:restoreAction];
    [alert addAction:cancelAction];

    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 长按手势回调

static void WCChangeTime_longPressHandler(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (!WCChangeTime_enabled()) return;

    UIView *timeCellView = gesture.view;
    if (!timeCellView) return;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    WCChangeTime_showEditor(timeCellView);
}

#pragma mark - Hook ChatTimeCellView

%hook ChatTimeCellView

- (void)didMoveToSuperview {
    %orig;

    if (!self.superview) return;

    UILongPressGestureRecognizer *existingGesture = objc_getAssociatedObject(self, &kWCCT_LongPressGestureKey);
    if (existingGesture) return;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(wcct_handleLongPress:)];
    longPress.minimumPressDuration = 0.8;
    self.userInteractionEnabled = YES;

    // tap 等 longPress 失败后才触发
    for (UIGestureRecognizer *gr in self.gestureRecognizers) {
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
            [gr requireGestureRecognizerToFail:longPress];
        }
    }
    UILabel *timeLabel = WCChangeTime_findTimeLabel(self);
    if (timeLabel) {
        for (UIGestureRecognizer *gr in timeLabel.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                [gr requireGestureRecognizerToFail:longPress];
            }
        }
    }

    [self addGestureRecognizer:longPress];
    objc_setAssociatedObject(self, &kWCCT_LongPressGestureKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)wcct_handleLongPress:(UILongPressGestureRecognizer *)gesture {
    WCChangeTime_longPressHandler(gesture);
}

%end

#pragma mark - Hook MMUILabel (\u62e6\u622a\u5c55\u5f00/\u6298\u53e0\u5207\u6362)

static NSString *WCChangeTime_resolveDisplayText(UIView *cellView, NSString *incomingText) {
    NSDate *origDate = objc_getAssociatedObject(cellView, &kWCCT_OrigDateKey);
    NSString *origShort = objc_getAssociatedObject(cellView, &kWCCT_OrigShortKey);
    NSString *origExpanded = objc_getAssociatedObject(cellView, &kWCCT_OrigExpandedKey);
    NSString *customShort = objc_getAssociatedObject(cellView, &kWCCT_CustomShortKey);
    NSString *customExpanded = objc_getAssociatedObject(cellView, &kWCCT_CustomExpandedKey);
    if (!customShort || !customExpanded) return nil;

    // 已经是自定义文本，跳过（防止重复处理）
    if ([incomingText isEqualToString:customShort] || [incomingText isEqualToString:customExpanded]) {
        return nil;
    }

    // 1) 精确匹配原始折叠文本
    if (origShort && [incomingText isEqualToString:origShort]) {
        return customShort;
    }
    // 2) 精确匹配原始展开文本
    if (origExpanded && [incomingText isEqualToString:origExpanded]) {
        return customExpanded;
    }

    // 3) 回退：解析传入文本的日期，和原始日期比对
    //    如果是同一条消息（60秒内），说明只是格式不同，仍然替换
    if (origDate) {
        NSDate *incomingDate = WCChangeTime_parseInputTime(incomingText);
        if (incomingDate) {
            NSTimeInterval diff = fabs([incomingDate timeIntervalSinceDate:origDate]);
            if (diff < 60) {
                BOOL expanded = WCChangeTime_textLooksExpanded(incomingText);
                return expanded ? customExpanded : customShort;
            }
        }
    }

    // 都不匹配 → cell 被复用了，清除自定义数据
    WCChangeTime_clearCustomData(cellView);
    return nil;
}

%hook MMUILabel

- (void)setText:(NSString *)text {
    if (kWCCT_IsSettingText) {
        %orig;
        return;
    }
    UIView *superView = self.superview;
    if (superView && [superView isKindOfClass:objc_getClass("ChatTimeCellView")]) {
        NSString *replacement = WCChangeTime_resolveDisplayText(superView, text);
        if (replacement) {
            %orig(replacement);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) {
                self.textToCopy = replacement;
            }
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
    UIView *superView = self.superview;
    if (superView && [superView isKindOfClass:objc_getClass("ChatTimeCellView")]) {
        NSString *incoming = attributedText.string ?: @"";
        NSString *replacement = WCChangeTime_resolveDisplayText(superView, incoming);
        if (replacement) {
            // 保留原有 attributed 属性，只换文本
            NSMutableAttributedString *mutAttr = [[NSMutableAttributedString alloc] initWithString:replacement];
            if (attributedText.length > 0) {
                NSDictionary *attrs = [attributedText attributesAtIndex:0 effectiveRange:NULL];
                if (attrs) {
                    [mutAttr setAttributes:attrs range:NSMakeRange(0, replacement.length)];
                }
            }
            %orig(mutAttr);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) {
                self.textToCopy = replacement;
            }
            return;
        }
    }
    %orig;
}

%end

#pragma mark - 构造函数：注册插件

%ctor {
    @autoreleasepool {
        // 默认关闭（不设置默认值，BOOL 默认为 NO）

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSClassFromString(@"WCPluginsMgr")) {
                [[objc_getClass("WCPluginsMgr") sharedInstance] registerSwitchWithTitle:@"WC-TIME" key:kWCChangeTimeEnabledKey];
            }
        });
    }
}
