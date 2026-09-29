#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>

// Plays downloaded audio files as a queue: advances to the next file automatically
// (also in the background) and adds previous/next controls under the system player.
@interface YTMUDownloadsPlayer : UIViewController
+ (instancetype)sharedPlayer;
- (void)playFiles:(NSArray<NSURL *> *)files startIndex:(NSUInteger)index;
@end
