#import "YTPlayerViewController.h"
#import "YTQueueController.h"

@interface YTMWatchViewController : UIViewController
@property (nonatomic, weak, readwrite) YTPlayerViewController *playerViewController;
@property (nonatomic, weak, readwrite) YTQueueController *queueController;

- (void)resetMiniplayerRestrictions;
@end