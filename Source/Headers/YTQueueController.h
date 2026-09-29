#import "YTQueueItem.h"

@interface YTQueueController : NSObject
@property (nonatomic, assign, readwrite) unsigned long long nowPlayingIndex;
@property (nonatomic, strong, readonly) NSArray<YTQueueItem *> *playbackQueueItems;
@property (nonatomic, assign, readonly) BOOL isRadioPlaylist;

- (void)playItemAtIndex:(unsigned long long)index;
@end
