#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MMUILabel : UILabel
@property (nonatomic, copy) NSString *textToCopy;
@property (nonatomic, assign) BOOL enableLongPressCopy;
@property (nonatomic, assign) NSInteger textStyle;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressCopyGesture;
@end

@interface BaseChatViewModel : NSObject
@property (nonatomic, weak) id cellView;
@property (nonatomic, assign) double createTime;
@property (nonatomic, assign) NSUInteger modelType;
@property (nonatomic, assign) NSUInteger splitPosition;
- (void)updateLayouts;
@end

@interface ChatTimeViewModel : BaseChatViewModel
@property (nonatomic, assign) double showingTime;
@property (nonatomic, readonly) NSString *timeText;
@property (nonatomic, readonly) double labelWidth;
@end

@interface ChatTimeCellView : UIView
@property (nonatomic, readonly) ChatTimeViewModel *viewModel;
- (void)setViewModel:(id)viewModel;
- (void)layoutInternal;
- (void)onClickTimeLabel;
@end

@interface BaseMsgContentViewController : UIViewController
@end

@interface WCPluginsMgr : NSObject
+ (instancetype)sharedInstance;
- (void)registerSwitchWithTitle:(NSString *)title key:(NSString *)key;
@end
