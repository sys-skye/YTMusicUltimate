#import "YTIPlaylistPanelVideoRenderer.h"

@interface YTQueueItem : NSObject
@property (nonatomic, strong, readwrite) YTIPlaylistPanelVideoRenderer *videoRenderer;
@property (nonatomic, strong, readwrite) YTIPlaylistPanelVideoRenderer *audioModeRenderer;
@property (nonatomic, strong, readwrite) YTIPlaylistPanelVideoRenderer *videoModeRenderer;
@end
