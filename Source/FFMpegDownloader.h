#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import "Utils/MobileFFmpeg/MobileFFmpegConfig.h"
#import "Utils/MobileFFmpeg/MobileFFmpeg.h"
#import "Utils/MobileFFmpeg/MobileFFprobe.h"
#import "Utils/MBProgressHUD/MBProgressHUD.h"
#import "Headers/Localization.h"

typedef NS_ENUM(NSInteger, FFMpegDownloadResult) {
    FFMpegDownloadResultSuccess,
    FFMpegDownloadResultCancelled,
    FFMpegDownloadResultFailed
};

@interface FFMpegDownloader : NSObject <LogDelegate, StatisticsDelegate>
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) NSString *tempName;
@property (nonatomic, strong) NSString *mediaName;
@property (nonatomic) NSInteger duration;
// Optional: shown before "Downloading" (e.g. "3/25"). When set, the per-track "Done" HUD is skipped.
@property (nonatomic, copy) NSString *progressPrefix;
// Optional: called on the main queue once the download finishes.
@property (nonatomic, copy) void (^completionHandler)(FFMpegDownloadResult result);
- (void)downloadAudio:(NSString *)audioURL;
- (void)downloadImage:(NSURL *)link;
- (void)shareMedia:(NSURL *)mediaURL;
@end