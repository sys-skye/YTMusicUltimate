#import "YTMUDownloadsPlayer.h"
#import <objc/runtime.h>

static void *YTMUCurrentItemContext = &YTMUCurrentItemContext;
static const char kYTMUItemIndexKey;

@interface YTMUDownloadsPlayer ()
@property (nonatomic, strong) AVPlayerViewController *playerViewController;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, copy) NSArray<NSURL *> *files;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, strong) UILabel *positionLabel;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@end

@implementation YTMUDownloadsPlayer

+ (instancetype)sharedPlayer {
    static YTMUDownloadsPlayer *sharedPlayer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedPlayer = [[self alloc] init];
    });
    return sharedPlayer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _player = [[AVQueuePlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
        [_player addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew context:YTMUCurrentItemContext];

        _playerViewController = [[AVPlayerViewController alloc] init];
        _playerViewController.player = _player;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    [self addChildViewController:self.playerViewController];
    UIView *playerView = self.playerViewController.view;
    playerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:playerView];
    [self.playerViewController didMoveToParentViewController:self];

    UIView *controlsView = [[UIView alloc] initWithFrame:CGRectZero];
    controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:controlsView];

    self.previousButton = [self controlButtonWithSymbol:@"backward.end.fill" action:@selector(previousTapped)];
    self.nextButton = [self controlButtonWithSymbol:@"forward.end.fill" action:@selector(nextTapped)];

    self.positionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.positionLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    self.positionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    self.positionLabel.textAlignment = NSTextAlignmentCenter;
    [self.positionLabel.widthAnchor constraintEqualToConstant:100].active = YES;

    UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.previousButton, self.positionLabel, self.nextButton]];
    stackView.axis = UILayoutConstraintAxisHorizontal;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.spacing = 24;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [controlsView addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [playerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [playerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [playerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [playerView.bottomAnchor constraintEqualToAnchor:controlsView.topAnchor],

        [controlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [controlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [controlsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [controlsView.heightAnchor constraintEqualToConstant:80],

        [stackView.centerXAnchor constraintEqualToAnchor:controlsView.centerXAnchor],
        [stackView.centerYAnchor constraintEqualToAnchor:controlsView.centerYAnchor],
    ]];

    [self updateControls];
}

- (UIButton *)controlButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration] forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:60].active = YES;
    [button.heightAnchor constraintEqualToConstant:60].active = YES;
    return button;
}

#pragma mark - Playback

- (void)playFiles:(NSArray<NSURL *> *)files startIndex:(NSUInteger)index {
    if (index >= files.count) return;

    self.files = files;
    [self activateAudioSession];
    [self playIndex:index];
}

- (void)activateAudioSession {
    NSError *error = nil;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if (![audioSession setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        NSLog(@"Error setting AVAudioSession category: %@", error.localizedDescription);
    }

    if (![audioSession setActive:YES error:&error]) {
        NSLog(@"Error activating AVAudioSession: %@", error.localizedDescription);
    }
}

- (void)playIndex:(NSUInteger)index {
    self.index = index;
    [self.player removeAllItems];
    [self.player insertItem:[self playerItemAtIndex:index] afterItem:nil];
    [self enqueueUpcomingItem];
    [self.player play];
    [self updateControls];
}

// Keeps the following file queued, so the player moves on by itself (also in the background)
- (void)enqueueUpcomingItem {
    if (self.index + 1 < self.files.count && self.player.items.count < 2) {
        [self.player insertItem:[self playerItemAtIndex:self.index + 1] afterItem:self.player.items.lastObject];
    }
}

- (AVPlayerItem *)playerItemAtIndex:(NSUInteger)index {
    NSURL *fileURL = self.files[index];
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:fileURL];
    objc_setAssociatedObject(playerItem, &kYTMUItemIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    AVMutableMetadataItem *titleMetadataItem = [AVMutableMetadataItem metadataItem];
    titleMetadataItem.key = AVMetadataCommonKeyTitle;
    titleMetadataItem.keySpace = AVMetadataKeySpaceCommon;
    titleMetadataItem.value = fileURL.lastPathComponent.stringByDeletingPathExtension;
    NSMutableArray *metadata = [NSMutableArray arrayWithObject:titleMetadataItem];

    NSData *artworkData = [NSData dataWithContentsOfURL:[[fileURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"png"]];
    if (artworkData) {
        AVMutableMetadataItem *artworkMetadataItem = [AVMutableMetadataItem metadataItem];
        artworkMetadataItem.key = AVMetadataCommonKeyArtwork;
        artworkMetadataItem.keySpace = AVMetadataKeySpaceCommon;
        artworkMetadataItem.value = artworkData;
        [metadata addObject:artworkMetadataItem];
    }

    playerItem.externalMetadata = metadata;
    return playerItem;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != YTMUCurrentItemContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *itemIndex = objc_getAssociatedObject(self.player.currentItem, &kYTMUItemIndexKey);
        if (itemIndex) {
            self.index = itemIndex.unsignedIntegerValue;
            [self enqueueUpcomingItem];
        }

        [self updateControls];
    });
}

- (void)previousTapped {
    // Like most players: restart the current track unless it just started
    if (self.index == 0 || CMTimeGetSeconds(self.player.currentTime) > 3) {
        [self.player seekToTime:kCMTimeZero];
        return;
    }

    [self playIndex:self.index - 1];
}

- (void)nextTapped {
    if (self.index + 1 < self.files.count) {
        [self playIndex:self.index + 1];
    }
}

- (void)updateControls {
    if (!self.isViewLoaded) return;

    self.positionLabel.text = self.files.count > 0 ? [NSString stringWithFormat:@"%lu / %lu", (unsigned long)self.index + 1, (unsigned long)self.files.count] : nil;
    self.previousButton.enabled = self.files.count > 0;
    self.nextButton.enabled = self.index + 1 < self.files.count;
}

@end
