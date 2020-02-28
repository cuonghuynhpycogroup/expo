//  Copyright © 2019 650 Industries. All rights reserved.

#import <EXUpdates/EXUpdatesConfig.h>
#import <EXUpdates/EXUpdatesAppController.h>
#import <EXUpdates/EXUpdatesAppLauncher.h>
#import <EXUpdates/EXUpdatesEmergencyAppLauncher.h>
#import <EXUpdates/EXUpdatesAppLauncherWithDatabase.h>
#import <EXUpdates/EXUpdatesEmbeddedAppLoader.h>
#import <EXUpdates/EXUpdatesRemoteAppLoader.h>
#import <EXUpdates/EXUpdatesReaper.h>
#import <EXUpdates/EXUpdatesSelectionPolicyNewest.h>
#import <EXUpdates/EXUpdatesUtils.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const kEXUpdatesUpdateAvailableEventName = @"updateAvailable";
static NSString * const kEXUpdatesNoUpdateAvailableEventName = @"noUpdateAvailable";
static NSString * const kEXUpdatesErrorEventName = @"error";
static NSString * const kEXUpdatesAppControllerErrorDomain = @"EXUpdatesAppController";

@interface EXUpdatesAppController ()

@property (nonatomic, readwrite, strong) id<EXUpdatesAppLauncher> launcher;
@property (nonatomic, readwrite, strong) EXUpdatesDatabase *database;
@property (nonatomic, readwrite, strong) id<EXUpdatesSelectionPolicy> selectionPolicy;
@property (nonatomic, readwrite, strong) EXUpdatesEmbeddedAppLoader *embeddedAppLoader;
@property (nonatomic, readwrite, strong) EXUpdatesRemoteAppLoader *remoteAppLoader;
@property (nonatomic, readwrite, strong) dispatch_queue_t assetFilesQueue;

@property (nonatomic, readwrite, strong) NSURL *updatesDirectory;
@property (nonatomic, readwrite, assign) BOOL isEnabled;

@property (nonatomic, strong) id<EXUpdatesAppLauncher> candidateLauncher;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL isReadyToLaunch;
@property (nonatomic, assign) BOOL isTimerFinished;
@property (nonatomic, assign) BOOL hasLaunched;
@property (nonatomic, strong) dispatch_queue_t controllerQueue;

@property (nonatomic, assign) BOOL isEmergencyLaunch;

@end

@implementation EXUpdatesAppController

+ (instancetype)sharedInstance
{
  static EXUpdatesAppController *theController;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!theController) {
      theController = [[EXUpdatesAppController alloc] init];
    }
  });
  return theController;
}

- (instancetype)init
{
  if (self = [super init]) {
    _database = [[EXUpdatesDatabase alloc] init];
    _selectionPolicy = [[EXUpdatesSelectionPolicyNewest alloc] init];
    _assetFilesQueue = dispatch_queue_create("expo.controller.AssetFilesQueue", DISPATCH_QUEUE_SERIAL);
    _controllerQueue = dispatch_queue_create("expo.controller.ControllerQueue", DISPATCH_QUEUE_SERIAL);
    _isEnabled = NO;
    _isReadyToLaunch = NO;
    _isTimerFinished = NO;
    _hasLaunched = NO;
  }
  return self;
}

- (void)start
{
  NSAssert(!_updatesDirectory, @"EXUpdatesAppController:start should only be called once per instance");
  dispatch_async(_controllerQueue, ^{
    self->_isEnabled = YES;
    NSError *fsError;
    self->_updatesDirectory = [EXUpdatesUtils initializeUpdatesDirectoryWithError:&fsError];
    if (fsError) {
      [self _emergencyLaunchWithFatalError:fsError];
      return;
    }

    NSError *dbError;
    if (![self->_database openDatabaseWithError:&dbError]) {
      [self _emergencyLaunchWithFatalError:dbError];
      return;
    }

    BOOL shouldCheckForUpdate = [EXUpdatesUtils shouldCheckForUpdate];
    NSNumber *launchWaitMs = [EXUpdatesConfig sharedInstance].launchWaitMs;
    if ([launchWaitMs isEqualToNumber:@(0)] || !shouldCheckForUpdate) {
      self->_isTimerFinished = YES;
    } else {
      NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:[launchWaitMs doubleValue] / 1000];
      self->_timer = [[NSTimer alloc] initWithFireDate:fireDate interval:0 target:self selector:@selector(_timerDidFire) userInfo:nil repeats:NO];
      [[NSRunLoop currentRunLoop] addTimer:self->_timer forMode:NSDefaultRunLoopMode];
    }

    [self _loadEmbeddedUpdateWithCompletion:^{
      [self _launchWithCompletion:^(NSError * _Nullable error, BOOL success) {
        dispatch_async(self->_controllerQueue, ^{
          if (!success) {
            [self _emergencyLaunchWithFatalError:error ?: [NSError errorWithDomain:kEXUpdatesAppControllerErrorDomain
                                                                         code:1010
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to find or load launch asset"}]];
          } else {
            self->_isReadyToLaunch = YES;
            [self _maybeFinish];
          }

          if (shouldCheckForUpdate) {
            [self _loadRemoteUpdateWithCompletion:^(NSError * _Nullable error, EXUpdatesUpdate * _Nullable update) {
              [self _handleRemoteUpdateLoaded:update error:error];
            }];
          } else {
            [self _runReaper];
          }
        });
      }];
    }];
  });
}

- (void)startAndShowLaunchScreen:(UIWindow *)window
{
  UIViewController *rootViewController = [UIViewController new];
  NSArray *views;
  @try {
    NSString *launchScreen = (NSString *)[[NSBundle mainBundle] objectForInfoDictionaryKey:@"UILaunchStoryboardName"] ?: @"LaunchScreen";
    views = [[NSBundle mainBundle] loadNibNamed:launchScreen owner:self options:nil];
  } @catch (NSException *_) {
    NSLog(@"LaunchScreen.xib is missing. Unexpected loading behavior may occur.");
  }
  if (views) {
    rootViewController.view = views.firstObject;
    rootViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  } else {
    UIView *view = [UIView new];
    view.backgroundColor = [UIColor whiteColor];;
    rootViewController.view = view;
  }
  window.rootViewController = rootViewController;
  [window makeKeyAndVisible];

  [self start];
}

- (void)requestRelaunchWithCompletion:(EXUpdatesAppControllerRelaunchCompletionBlock)completion
{
  if (_bridge) {
    EXUpdatesAppLauncherWithDatabase *launcher = [[EXUpdatesAppLauncherWithDatabase alloc] init];
    _candidateLauncher = launcher;
    [launcher launchUpdateWithSelectionPolicy:self->_selectionPolicy completion:^(NSError * _Nullable error, BOOL success) {
      if (success) {
        dispatch_async(self->_controllerQueue, ^{
          self->_launcher = self->_candidateLauncher;
          completion(YES);
          [self->_bridge reload];
          [self _runReaper];
        });
      } else {
        NSLog(@"Failed to relaunch: %@", error.localizedDescription);
        completion(NO);
      }
    }];
  } else {
    NSLog(@"EXUpdatesAppController: Failed to reload because bridge was nil. Did you set the bridge property on the controller singleton?");
    completion(NO);
  }
}

- (nullable EXUpdatesUpdate *)launchedUpdate
{
  return _launcher.launchedUpdate ?: nil;
}

- (nullable NSURL *)launchAssetUrl
{
  return _launcher.launchAssetUrl ?: nil;
}

- (nullable NSDictionary *)assetFilesMap
{
  return _launcher.assetFilesMap ?: nil;
}

# pragma mark - internal

- (void)_maybeFinish
{
  if (!_isTimerFinished || !_isReadyToLaunch) {
    // too early, bail out
    return;
  }
  if (_hasLaunched) {
    // we've already fired once, don't do it again
    return;
  }

  // TODO: remove this assertion and replace it with
  // [self _emergencyLaunchWithError:];
  NSAssert(self.launchAssetUrl != nil, @"_maybeFinish should only be called when we have a valid launchAssetUrl");

  _hasLaunched = YES;
  if (self->_delegate) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_delegate appController:self didStartWithSuccess:YES];
    });
  }
}

- (void)_timerDidFire
{
  dispatch_async(_controllerQueue, ^{
    self->_isTimerFinished = YES;
    [self _maybeFinish];
  });
}

- (void)_loadEmbeddedUpdateWithCompletion:(void (^)(void))completion
{
  [EXUpdatesAppLauncherWithDatabase launchableUpdateWithSelectionPolicy:_selectionPolicy completion:^(NSError * _Nullable error, EXUpdatesUpdate * _Nullable launchableUpdate) {
    if ([self->_selectionPolicy shouldLoadNewUpdate:[EXUpdatesEmbeddedAppLoader embeddedManifest] withLaunchedUpdate:launchableUpdate]) {
      self->_embeddedAppLoader = [[EXUpdatesEmbeddedAppLoader alloc] init];
      [self->_embeddedAppLoader loadUpdateFromEmbeddedManifestWithSuccess:^(EXUpdatesUpdate * _Nullable update) {
        completion();
      } error:^(NSError * _Nonnull error) {
        completion();
      }];
    } else {
      completion();
    }
  }];
}

- (void)_launchWithCompletion:(void (^)(NSError * _Nullable error, BOOL success))completion
{
  EXUpdatesAppLauncherWithDatabase *launcher = [[EXUpdatesAppLauncherWithDatabase alloc] init];
  _launcher = launcher;
  [launcher launchUpdateWithSelectionPolicy:_selectionPolicy completion:completion];
}

- (void)_loadRemoteUpdateWithCompletion:(void (^)(NSError * _Nullable error, EXUpdatesUpdate * _Nullable update))completion
{
  _remoteAppLoader = [[EXUpdatesRemoteAppLoader alloc] init];
  [_remoteAppLoader loadUpdateFromUrl:[EXUpdatesConfig sharedInstance].remoteUrl success:^(EXUpdatesUpdate * _Nullable update) {
    completion(nil, update);
  } error:^(NSError *error) {
    completion(error, nil);
  }];
}

- (void)_handleRemoteUpdateLoaded:(nullable EXUpdatesUpdate *)update error:(nullable NSError *)error
{
  // If the app has not yet been launched (because the timer is still running),
  // create a new launcher so that we can launch with the newly downloaded update.
  // Otherwise, we've already launched. Send an event to the notify JS of the new update.

  dispatch_async(_controllerQueue, ^{
    if (self->_timer) {
      [self->_timer invalidate];
    }
    self->_isTimerFinished = YES;

    if (update) {
      if (!self->_hasLaunched) {
        EXUpdatesAppLauncherWithDatabase *launcher = [[EXUpdatesAppLauncherWithDatabase alloc] init];
        self->_candidateLauncher = launcher;
        [launcher launchUpdateWithSelectionPolicy:self->_selectionPolicy completion:^(NSError * _Nullable error, BOOL success) {
          dispatch_async(self->_controllerQueue, ^{
            if (success) {
              if (!self->_hasLaunched) {
                self->_launcher = self->_candidateLauncher;
                [self _maybeFinish];
              }
            } else {
              [self _maybeFinish];
              NSLog(@"Downloaded update but failed to relaunch: %@", error.localizedDescription);
            }
          });
        }];
      } else {
        [EXUpdatesUtils sendEventToBridge:self->_bridge
                                 withType:kEXUpdatesUpdateAvailableEventName
                                     body:@{@"manifest": update.rawManifest}];
      }
    } else {
      // there's no update, so signal we're ready to launch
      [self _maybeFinish];
      if (error) {
        [EXUpdatesUtils sendEventToBridge:self->_bridge
                                 withType:kEXUpdatesErrorEventName
                                     body:@{@"message": error.localizedDescription}];
      } else {
        [EXUpdatesUtils sendEventToBridge:self->_bridge withType:kEXUpdatesNoUpdateAvailableEventName body:@{}];
      }
    }

    [self _runReaper];
  });
}

- (void)_runReaper
{
  if (_launcher.launchedUpdate) {
    [EXUpdatesReaper reapUnusedUpdatesWithSelectionPolicy:self->_selectionPolicy
                                           launchedUpdate:self->_launcher.launchedUpdate];
  }
}

- (void)_emergencyLaunchWithFatalError:(NSError *)error
{
  if (_timer) {
    [_timer invalidate];
  }

  _isEmergencyLaunch = YES;
  _hasLaunched = YES;

  EXUpdatesEmergencyAppLauncher *launcher = [[EXUpdatesEmergencyAppLauncher alloc] init];
  _launcher = launcher;
  [launcher launchUpdateWithFatalError:error];

  if (_delegate) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_delegate appController:self didStartWithSuccess:self.launchAssetUrl != nil];
    });
  }
}

@end

NS_ASSUME_NONNULL_END
