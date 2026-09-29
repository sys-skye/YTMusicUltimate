#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"
#import "Headers/YTQueueController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

// Newer YT Music (9.34+) renamed -[YTPlayerViewController playerResponse] to -contentPlayerResponse.
static YTPlayerResponse *YTMUPlayerResponse(YTPlayerViewController *playerVC) {
    if ([playerVC respondsToSelector:@selector(contentPlayerResponse)]) return playerVC.contentPlayerResponse;
    if ([playerVC respondsToSelector:@selector(playerResponse)]) return playerVC.playerResponse;
    return nil;
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

static NSString *YTMULocalized(NSString *key, NSString *fallback) {
    NSString *string = LOC(key);
    return (string.length > 0 && ![string isEqualToString:key]) ? string : fallback;
}

static void YTMUShowInfo(NSString *title, NSString *subtitle) {
    YTAlertView *alertView = [%c(YTAlertView) infoDialog];
    alertView.title = title;
    alertView.subtitle = subtitle;
    [alertView show];
}

static NSString *YTMUAudioURLFromManifest(NSURL *manifest) {
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

static NSString *YTMUMediaName(YTPlayerResponse *playerResponse) {
    YTIVideoDetails *videoDetails = playerResponse.playerData.videoDetails;
    NSString *title = [videoDetails.title stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [videoDetails.author stringByReplacingOccurrencesOfString:@"/" withString:@""];
    return [NSString stringWithFormat:@"%@ - %@", author, title];
}

static NSURL *YTMUDownloadsFolderURL(void) {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
}

// Downloads the audio (and cover) of the track currently loaded in playerVC. Returns NO if no audio link was found.
static BOOL YTMUDownloadAudio(YTPlayerViewController *playerVC, NSString *progressPrefix, void (^completion)(FFMpegDownloadResult result)) {
    YTPlayerResponse *playerResponse = YTMUPlayerResponse(playerVC);
    YTIVideoDetails *videoDetails = playerResponse.playerData.videoDetails;
    NSString *mediaName = YTMUMediaName(playerResponse);

    NSString *extractedURL = YTMUAudioURLFromManifest([NSURL URLWithString:playerResponse.playerData.streamingData.hlsManifestURL]);
    if (extractedURL.length == 0) return NO;

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = videoDetails.videoId.length > 0 ? videoDetails.videoId : playerVC.contentVideoID;
    ffmpeg.mediaName = mediaName;
    ffmpeg.duration = videoDetails.lengthSeconds > 0 ? videoDetails.lengthSeconds : round(playerVC.currentVideoTotalMediaTime);
    ffmpeg.progressPrefix = progressPrefix;
    ffmpeg.completionHandler = completion;
    [ffmpeg downloadAudio:extractedURL];

    NSMutableArray *thumbnailsArray = videoDetails.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];

    if (imageData) {
        NSURL *coverURL = [YTMUDownloadsFolderURL() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", mediaName]];
        [imageData writeToURL:coverURL atomically:YES];
    }

    return YES;
}

#pragma mark - Queue downloading

// Downloads every track from the now playing one to the end of the queue, one after another.
// The tweak can only download a track once the player has loaded it (that's where the stream link comes from),
// so each track is played, paused as soon as its player response arrives, and then downloaded.
@interface YTMUQueueDownloader : NSObject
@property (nonatomic, weak) YTPlayerViewController *playerVC;
@property (nonatomic, weak) YTQueueController *queueController;
@property (nonatomic, assign) NSUInteger startIndex;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, assign) NSUInteger fixedEndIndex; // radio queues keep growing, so they are limited to their initial size
@property (nonatomic, assign) NSUInteger downloaded;
@property (nonatomic, assign) NSUInteger skipped;
@property (nonatomic, assign) NSUInteger failed;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSUInteger polls;
@property (nonatomic, assign) BOOL wasIdleTimerDisabled;
+ (BOOL)canDownloadWithQueueController:(YTQueueController *)queueController;
+ (void)startWithPlayerViewController:(YTPlayerViewController *)playerVC queueController:(YTQueueController *)queueController;
@end

static YTMUQueueDownloader *activeQueueDownloader;
static const NSUInteger kYTMUQueueMaxTracks = 500;
static const NSTimeInterval kYTMUQueuePollInterval = 0.5;
static const NSUInteger kYTMUQueueMaxPolls = 60; // give each track 30 seconds to load

@implementation YTMUQueueDownloader

+ (BOOL)canDownloadWithQueueController:(YTQueueController *)queueController {
    return [queueController respondsToSelector:@selector(playbackQueueItems)]
        && [queueController respondsToSelector:@selector(nowPlayingIndex)]
        && [queueController respondsToSelector:@selector(playItemAtIndex:)];
}

+ (void)startWithPlayerViewController:(YTPlayerViewController *)playerVC queueController:(YTQueueController *)queueController {
    if (activeQueueDownloader) {
        YTMUShowInfo(YTMULocalized(@"QUEUE_DOWNLOAD_RUNNING", @"Queue download already running"), nil);
        return;
    }

    NSUInteger count = queueController.playbackQueueItems.count;
    if (!playerVC || count == 0) {
        YTMUShowInfo(YTMULocalized(@"QUEUE_EMPTY", @"Nothing in the queue"), nil);
        return;
    }

    YTMUQueueDownloader *downloader = [[self alloc] init];
    downloader.playerVC = playerVC;
    downloader.queueController = queueController;
    downloader.startIndex = queueController.nowPlayingIndex < count ? queueController.nowPlayingIndex : 0;
    downloader.index = downloader.startIndex;
    BOOL isRadio = [queueController respondsToSelector:@selector(isRadioPlaylist)] && queueController.isRadioPlaylist;
    downloader.fixedEndIndex = isRadio ? count : NSUIntegerMax;

    // Keep the screen on, the app gets suspended (and the download stalls) once the phone locks
    downloader.wasIdleTimerDisabled = [UIApplication sharedApplication].idleTimerDisabled;
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    activeQueueDownloader = downloader;
    [downloader processCurrentIndex];
}

- (NSUInteger)endIndex {
    NSUInteger end = MIN(self.queueController.playbackQueueItems.count, self.fixedEndIndex);
    return MIN(end, self.startIndex + kYTMUQueueMaxTracks);
}

- (NSSet<NSString *> *)videoIDsForItem:(id)item {
    NSMutableSet<NSString *> *videoIDs = [NSMutableSet set];
    for (NSString *key in @[@"videoRenderer", @"audioModeRenderer", @"videoModeRenderer"]) {
        if (![item respondsToSelector:NSSelectorFromString(key)]) continue;

        YTIPlaylistPanelVideoRenderer *renderer = [item valueForKey:key];
        NSString *videoID = [renderer respondsToSelector:@selector(videoId)] ? renderer.videoId : nil;
        if (videoID.length > 0) [videoIDs addObject:videoID];
    }

    return videoIDs;
}

- (void)processCurrentIndex {
    YTQueueController *queueController = self.queueController;
    YTPlayerViewController *playerVC = self.playerVC;
    if (!queueController || !playerVC || self.index >= [self endIndex]) {
        [self finishCancelled:NO];
        return;
    }

    // Not every queue row is a song (e.g. headers), those have no video ID
    NSSet<NSString *> *videoIDs = [self videoIDsForItem:queueController.playbackQueueItems[self.index]];
    if (videoIDs.count == 0) {
        [self advance];
        return;
    }

    NSString *loadedVideoID = YTMUPlayerResponse(playerVC).playerData.videoDetails.videoId;
    if (![videoIDs containsObject:loadedVideoID ?: @""]) {
        [queueController playItemAtIndex:self.index];
    }

    self.polls = 0;
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer timerWithTimeInterval:kYTMUQueuePollInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf pollForTrackWithVideoIDs:videoIDs];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)pollForTrackWithVideoIDs:(NSSet<NSString *> *)videoIDs {
    self.polls++;

    YTPlayerViewController *playerVC = self.playerVC;
    YTIPlayerResponse *playerData = YTMUPlayerResponse(playerVC).playerData;
    NSString *videoID = playerData.videoDetails.videoId;
    BOOL isLoaded = videoID.length > 0 && [videoIDs containsObject:videoID] && playerData.streamingData.hlsManifestURL.length > 0;

    if (!isLoaded) {
        if (!playerVC || self.polls >= kYTMUQueueMaxPolls) {
            [self stopPolling];
            self.failed++;
            [self advance];
        }
        return;
    }

    [self stopPolling];
    if ([playerVC respondsToSelector:@selector(pause)]) [playerVC pause];
    [self downloadLoadedTrack];
}

- (void)downloadLoadedTrack {
    YTPlayerViewController *playerVC = self.playerVC;

    NSString *fileName = [NSString stringWithFormat:@"%@.m4a", YTMUMediaName(YTMUPlayerResponse(playerVC))];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[YTMUDownloadsFolderURL() URLByAppendingPathComponent:fileName].path]) {
        self.skipped++;
        [self advance];
        return;
    }

    NSString *progressPrefix = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(self.index - self.startIndex + 1), (unsigned long)([self endIndex] - self.startIndex)];
    __weak typeof(self) weakSelf = self;
    BOOL started = YTMUDownloadAudio(playerVC, progressPrefix, ^(FFMpegDownloadResult result) {
        YTMUQueueDownloader *strongSelf = weakSelf;
        if (!strongSelf) return;

        if (result == FFMpegDownloadResultCancelled) {
            [strongSelf finishCancelled:YES];
            return;
        }

        if (result == FFMpegDownloadResultSuccess) strongSelf.downloaded++;
        else strongSelf.failed++;
        [strongSelf advance];
    });

    if (!started) {
        self.failed++;
        [self advance];
    }
}

- (void)advance {
    self.index++;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processCurrentIndex];
    });
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)finishCancelled:(BOOL)cancelled {
    [self stopPolling];
    if (activeQueueDownloader != self) return;
    activeQueueDownloader = nil;

    [UIApplication sharedApplication].idleTimerDisabled = self.wasIdleTimerDisabled;

    NSString *title = cancelled ? YTMULocalized(@"QUEUE_DOWNLOAD_STOPPED", @"Queue download stopped") : YTMULocalized(@"QUEUE_DOWNLOAD_FINISHED", @"Queue download finished");
    NSString *format = YTMULocalized(@"QUEUE_DOWNLOAD_SUMMARY", @"%lu downloaded, %lu already downloaded, %lu failed");
    YTMUShowInfo(title, [NSString stringWithFormat:format, (unsigned long)self.downloaded, (unsigned long)self.skipped, (unsigned long)self.failed]);
}

@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }


    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;
    YTMWatchViewController *watchVC = (YTMWatchViewController *)playingVC.parentViewController;
    YTPlayerViewController *playerVC = watchVC.playerViewController;
    YTPlayerResponse *playerResponse = YTMUPlayerResponse(playerVC);

    if (playerResponse) {
        BOOL downloadAudio = YTMU(@"downloadAudio");
        BOOL downloadCover = YTMU(@"downloadCoverImage");

        if (!downloadAudio) {
            if (downloadCover) [self downloadCoverImage:playerVC];
            return;
        }

        YTQueueController *queueController = [watchVC respondsToSelector:@selector(queueController)] ? watchVC.queueController : nil;

        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC];
        }]];

        if ([YTMUQueueDownloader canDownloadWithQueueController:queueController]) {
            [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:YTMULocalized(@"DOWNLOAD_QUEUE", @"Download rest of queue") iconImage:[%c(YTUIResources) downloadOutline] style:0 handler:^ {
                [YTMUQueueDownloader startWithPlayerViewController:playerVC queueController:queueController];
            }]];
        }

        if (downloadCover) {
            [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
                [self downloadCoverImage:playerVC];
            }]];
        }

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    if (!YTMUDownloadAudio(playerVC, nil, nil)) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    YTPlayerResponse *playerResponse = YTMUPlayerResponse(playerVC);

    NSMutableArray *thumbnailsArray = playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [hud hideAnimated:YES];
    });
}
%end
