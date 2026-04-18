#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface MMUILabel : UILabel
@property (nonatomic, copy) NSString *textToCopy;
@property (nonatomic, assign) BOOL enableLongPressCopy;
@property (nonatomic, assign) NSInteger textStyle;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressCopyGesture;
@end

@interface ChatTimeCellView : UIView
@end

@interface BaseMsgContentViewController : UIViewController
@end

@interface WCPluginsMgr : NSObject
+ (instancetype)sharedInstance;
- (void)registerSwitchWithTitle:(NSString *)title key:(NSString *)key;
@end
