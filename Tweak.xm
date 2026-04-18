// Tweak.xm
// WeChatChangeTime - 长按聊天时间行修改显示时间
//
// 功能：
//   1) 在 ChatTimeCellView 上添加长按手势，弹出时间编辑弹窗
//   2) 修改后的时间适配微信原有格式（短格式/展开格式）
//   3) 适配微信自带的单击展开时间功能
//   4) 通过 WCPluginsMgr 注册插件开关

#import "WeChatHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static NSString *const kWCChangeTimeEnabledKey = @"WCChangeTimeEnabled";

static BOOL WCChangeTime_enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCChangeTimeEnabledKey];
}

#pragma mark - 关联对象 Key

static char kWCCT_OriginalDateKey;       // 存储修改后对应的 NSDate
static char kWCCT_ShortFormatKey;        // 存储短格式文本
static char kWCCT_ExpandedFormatKey;     // 存储展开格式文本
static char kWCCT_IsExpandedKey;         // 当前是否展开状态
static char kWCCT_LongPressGestureKey;   // 长按手势

static BOOL kWCCT_IsSettingText = NO;    // 重入保护标志

#pragma mark - 时间格式化工具

static NSString *WCChangeTime_shortFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    NSDateComponents *todayComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSDate *todayStart = [calendar dateFromComponents:todayComponents];

    NSDateComponents *targetComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitWeekday) fromDate:date];

    NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
    timeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    timeFmt.dateFormat = @"HH:mm";
    NSString *timeStr = [timeFmt stringFromDate:date];

    NSTimeInterval diff = [todayStart timeIntervalSinceDate:date];

    // 今天
    if (diff <= 0 && [calendar isDateInToday:date]) {
        return timeStr;
    }

    // 昨天
    if ([calendar isDateInYesterday:date]) {
        return [NSString stringWithFormat:@"昨天 %@", timeStr];
    }

    // 本周内（7天内）显示星期几
    NSDate *weekAgo = [now dateByAddingTimeInterval:-6 * 24 * 3600];
    if ([date compare:weekAgo] != NSOrderedAscending) {
        NSArray *weekdays = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
        NSString *weekday = weekdays[targetComponents.weekday];
        return [NSString stringWithFormat:@"%@ %@", weekday, timeStr];
    }

    // 今年内
    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];
    if (targetComponents.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@", (long)targetComponents.month, (long)targetComponents.day, timeStr];
    }

    // 跨年
    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@", (long)targetComponents.year, (long)targetComponents.month, (long)targetComponents.day, timeStr];
}

static NSString *WCChangeTime_expandedFormat(NSDate *date) {
    if (!date) return nil;

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    NSDateComponents *targetComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitWeekday) fromDate:date];

    NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
    timeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    timeFmt.dateFormat = @"HH:mm";
    NSString *timeStr = [timeFmt stringFromDate:date];

    NSArray *weekdays = @[@"", @"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
    NSString *weekday = weekdays[targetComponents.weekday];

    NSInteger currentYear = [calendar component:NSCalendarUnitYear fromDate:now];

    if (targetComponents.year == currentYear) {
        return [NSString stringWithFormat:@"%ld月%ld日 %@ %@", (long)targetComponents.month, (long)targetComponents.day, weekday, timeStr];
    }

    return [NSString stringWithFormat:@"%ld年%ld月%ld日 %@ %@", (long)targetComponents.year, (long)targetComponents.month, (long)targetComponents.day, weekday, timeStr];
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

#pragma mark - 尝试解析用户输入的时间字符串

static NSDate *WCChangeTime_parseInputTime(NSString *input) {
    if (!input || input.length == 0) return nil;

    input = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray *formats = @[
        @"yyyy-MM-dd HH:mm",
        @"yyyy/MM/dd HH:mm",
        @"yyyy年MM月dd日 HH:mm",
        @"MM-dd HH:mm",
        @"MM/dd HH:mm",
        @"MM月dd日 HH:mm",
        @"HH:mm",
    ];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.timeZone = [NSTimeZone localTimeZone];

    for (NSString *format in formats) {
        fmt.dateFormat = format;
        NSDate *date = [fmt dateFromString:input];
        if (date) {
            // 如果只输入了时间（HH:mm），用今天的日期
            if ([format isEqualToString:@"HH:mm"]) {
                NSCalendar *cal = [NSCalendar currentCalendar];
                NSDateComponents *todayComp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:[NSDate date]];
                NSDateComponents *timeComp = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                todayComp.hour = timeComp.hour;
                todayComp.minute = timeComp.minute;
                return [cal dateFromComponents:todayComp];
            }
            // 如果没有年份（MM-dd / MM/dd / MM月dd日），用当前年
            if ([format hasPrefix:@"MM"]) {
                NSCalendar *cal = [NSCalendar currentCalendar];
                NSInteger currentYear = [cal component:NSCalendarUnitYear fromDate:[NSDate date]];
                NSDateComponents *comp = [cal components:(NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
                comp.year = currentYear;
                return [cal dateFromComponents:comp];
            }
            return date;
        }
    }
    return nil;
}

#pragma mark - 弹出编辑弹窗

static void WCChangeTime_showEditor(UIView *timeCellView) {
    UILabel *label = WCChangeTime_findTimeLabel(timeCellView);
    if (!label) return;

    UIViewController *vc = WCChangeTime_findViewController(timeCellView);
    if (!vc) return;

    NSString *currentText = label.text ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WC-TIME"
                                                                  message:@"修改聊天时间显示\n支持格式: HH:mm / MM-dd HH:mm / yyyy-MM-dd HH:mm\n例: 14:30 / 03-29 22:50 / 2025-03-29 22:50"
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
                                                                             message:@"无法解析输入的时间，请使用以下格式:\nHH:mm (如 14:30)\nMM-dd HH:mm (如 03-29 22:50)\nyyyy-MM-dd HH:mm (如 2025-03-29 22:50)"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [errAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:errAlert animated:YES completion:nil];
            return;
        }

        NSString *shortText = WCChangeTime_shortFormat(newDate);
        NSString *expandedText = WCChangeTime_expandedFormat(newDate);

        objc_setAssociatedObject(timeCellView, &kWCCT_OriginalDateKey, newDate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_ShortFormatKey, shortText, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_ExpandedFormatKey, expandedText, OBJC_ASSOCIATION_COPY_NONATOMIC);

        // 判断当前是否为展开状态
        BOOL isExpanded = [objc_getAssociatedObject(timeCellView, &kWCCT_IsExpandedKey) boolValue];
        NSString *displayText = isExpanded ? expandedText : shortText;

        kWCCT_IsSettingText = YES;
        label.text = displayText;
        kWCCT_IsSettingText = NO;
        if ([label respondsToSelector:@selector(setTextToCopy:)]) {
            [(id)label setTextToCopy:displayText];
        }

        [label sizeToFit];
        // 居中标签
        CGRect labelFrame = label.frame;
        labelFrame.origin.x = (timeCellView.bounds.size.width - labelFrame.size.width) / 2.0;
        label.frame = labelFrame;
    }];

    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // 清除关联对象，让微信自己的逻辑重新生效
        objc_setAssociatedObject(timeCellView, &kWCCT_OriginalDateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_ShortFormatKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_ExpandedFormatKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(timeCellView, &kWCCT_IsExpandedKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    // 触觉反馈
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    WCChangeTime_showEditor(timeCellView);
}

#pragma mark - Hook ChatTimeCellView

%hook ChatTimeCellView

- (void)didMoveToSuperview {
    %orig;

    if (!self.superview) return;

    // 避免重复添加手势
    UILongPressGestureRecognizer *existingGesture = objc_getAssociatedObject(self, &kWCCT_LongPressGestureKey);
    if (existingGesture) return;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(wcct_handleLongPress:)];
    longPress.minimumPressDuration = 0.8;
    self.userInteractionEnabled = YES;

    // 避免和微信自带的 tap 手势冲突：tap 需等 longPress 失败后才触发
    for (UIGestureRecognizer *gr in self.gestureRecognizers) {
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
            [gr requireGestureRecognizerToFail:longPress];
        }
    }

    // 同时处理子视图 MMUILabel 上的手势
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

#pragma mark - Hook MMUILabel (拦截微信单击展开/折叠时间)

%hook MMUILabel

- (void)setText:(NSString *)text {
    if (kWCCT_IsSettingText) {
        %orig;
        return;
    }

    UIView *superView = self.superview;
    if (superView && [superView isKindOfClass:objc_getClass("ChatTimeCellView")]) {
        NSString *customShort = objc_getAssociatedObject(superView, &kWCCT_ShortFormatKey);
        if (customShort) {
            // 检测微信是否正在切换展开/折叠
            NSString *customExpanded = objc_getAssociatedObject(superView, &kWCCT_ExpandedFormatKey);
            BOOL wasExpanded = [objc_getAssociatedObject(superView, &kWCCT_IsExpandedKey) boolValue];

            // 微信在 setText 时切换展开状态，我们跟随切换
            NSString *oldText = self.text;
            if (oldText && text && ![oldText isEqualToString:text]) {
                // 微信正在切换，同步切换我们的文本
                BOOL nowExpanded = !wasExpanded;
                objc_setAssociatedObject(superView, &kWCCT_IsExpandedKey, @(nowExpanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSString *displayText = nowExpanded ? customExpanded : customShort;
                %orig(displayText);
                if ([self respondsToSelector:@selector(setTextToCopy:)]) {
                    self.textToCopy = displayText;
                }
                return;
            }

            // 非切换，使用当前状态的文本
            BOOL isExpanded = [objc_getAssociatedObject(superView, &kWCCT_IsExpandedKey) boolValue];
            NSString *displayText = isExpanded ? customExpanded : customShort;
            %orig(displayText);
            if ([self respondsToSelector:@selector(setTextToCopy:)]) {
                self.textToCopy = displayText;
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
        // 默认启用
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults objectForKey:kWCChangeTimeEnabledKey] == nil) {
            [defaults setBool:YES forKey:kWCChangeTimeEnabledKey];
            [defaults synchronize];
        }

        // 注册到 WCPluginsMgr
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSClassFromString(@"WCPluginsMgr")) {
                [[objc_getClass("WCPluginsMgr") sharedInstance] registerSwitchWithTitle:@"WC-TIME" key:kWCChangeTimeEnabledKey];
            }
        });
    }
}
