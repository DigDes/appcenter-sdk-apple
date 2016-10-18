/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import "SNMAppleErrorLog.h"
#import "SNMCrashesCXXExceptionWrapperException.h"
#import "SNMCrashesDelegate.h"
#import "SNMCrashesHelper.h"
#import "SNMCrashesPrivate.h"
#import "SNMErrorLogFormatter.h"
#import "SNMFeatureAbstractProtected.h"
#import "SNMSonomaInternal.h"
#import "SonomaCore+Internal.h"
#import <CrashReporter/CrashReporter.h>

/**
 *  Feature name.
 */
static NSString *const kSNMFeatureName = @"Crashes";
static NSString *const kSNMAnalyzerFilename = @"SNMCrashes.analyzer";

#pragma mark - Callbacks Setup

static SNMCrashesCallbacks snmCrashesCallbacks = {.context = NULL, .handleSignal = NULL};
static NSString *const kSNMUserConfirmationKey = @"kSNMUserConfirmationKey";

/** Proxy implementation for PLCrashReporter to keep our interface stable while
 *  this can change.
 */
static void plcr_post_crash_callback(siginfo_t *info, ucontext_t *uap, void *context) {
  if (snmCrashesCallbacks.handleSignal != NULL) {
    snmCrashesCallbacks.handleSignal(context);
  }
}

static PLCrashReporterCallbacks plCrashCallbacks = {
    .version = 0, .context = NULL, .handleSignal = plcr_post_crash_callback};

/**
 * C++ Exception Handler
 */
static void uncaught_cxx_exception_handler(const SNMCrashesUncaughtCXXExceptionInfo *info) {
  // This relies on a LOT of sneaky internal knowledge of how PLCR works and
  // should not be considered a long-term solution.
  NSGetUncaughtExceptionHandler()([[SNMCrashesCXXExceptionWrapperException alloc] initWithCXXExceptionInfo:info]);
  abort();
}

@interface SNMCrashes () <SNMChannelDelegate>

@end

@implementation SNMCrashes

@synthesize delegate = _delegate;
@synthesize logManager = _logManager;

#pragma mark - Public Methods

+ (void)generateTestCrash {
  @synchronized ([self sharedInstance]) {
    if ([[self sharedInstance] canBeUsed]) {
      if ([SNMEnvironmentHelper currentAppEnvironment] != SNMEnvironmentAppStore) {
        if ([SNMSonoma isDebuggerAttached]) {
          SNMLogWarning(@"[SNMCrashes] WARNING: The debugger is attached. The following crash cannot be detected by the SDK!");
        }

        __builtin_trap();
      }
    } else {
      SNMLogWarning(@"[SNMCrashes] WARNING: GenerateTestCrash was just called in an App Store environment. The call will "
                        @"be ignored");
    }
  }
}

+ (BOOL)hasCrashedInLastSession {
  return [[self sharedInstance] didCrashInLastSession];
}

+ (void)setUserConfirmationHandler:(_Nullable SNMUserConfirmationHandler)userConfirmationHandler {
  ((SNMCrashes *) [self sharedInstance]).userConfirmationHandler = userConfirmationHandler;
}

+ (void)notifyWithUserConfirmation:(SNMUserConfirmation)userConfirmation {
  SNMCrashes *crashes = [self sharedInstance];

  if (userConfirmation == SNMUserConfirmationDontSend) {

    // Don't send logs. Clean up files.
    for (NSString *filePath in [crashes unprocessedFilePaths]) {
      [crashes deleteCrashReportWithFilePath:filePath];
      [crashes.crashFiles removeObject:filePath];
    }
    return;
  } else if (userConfirmation == SNMUserConfirmationAlways) {

    // Always send logs. Set the flag true to bypass user confirmation next time.
    [kSNMUserDefaults setObject:[[NSNumber alloc] initWithBool:YES] forKey:kSNMUserConfirmationKey];
  }

  // Process crashes logs.
  for (int i = 0; i < [crashes.unprocessedReports count]; i++) {
    SNMAppleErrorLog *log = [crashes.unprocessedLogs objectAtIndex:i];
    SNMErrorReport *report = [crashes.unprocessedReports objectAtIndex:i];
    NSString *filePath = [crashes.unprocessedFilePaths objectAtIndex:i];

    // Get error attachment.
    [log setErrorAttachment:[crashes.delegate attachmentWithCrashes:crashes forErrorReport:report]];

    // Send log to log manager.
    [crashes.logManager processLog:log withPriority:crashes.priority];
    [crashes deleteCrashReportWithFilePath:filePath];
    [crashes.crashFiles removeObject:filePath];
  }
}

+ (SNMErrorReport *_Nullable)lastSessionCrashReport {

  return [[self sharedInstance] getLastSessionCrashReport];
}

+ (void)setDelegate:(_Nullable id <SNMCrashesDelegate>)delegate {
  [[self sharedInstance] setDelegate:delegate];
}

#pragma mark - Module initialization

- (instancetype)init {
  if ((self = [super init])) {
    _fileManager = [[NSFileManager alloc] init];
    _crashFiles = [[NSMutableArray alloc] init];
    _crashesDir = [SNMCrashesHelper crashesDir];
    _analyzerInProgressFile = [_crashesDir stringByAppendingPathComponent:kSNMAnalyzerFilename];
    _didCrashInLastSession = NO;
  }
  return self;
}

#pragma mark - SNMFeatureAbstract

- (void)setEnabled:(BOOL)isEnabled {
  [super setEnabled:isEnabled];

  if (isEnabled) {
    SNMLogDebug(@"[SNMCrashes] DEBUG: Enabling crashes feature again.");
    [self configureCrashReporter];
    [self.logManager addChannelDelegate:self forPriority:SNMPriorityHigh];
  } else {
    // Don't set PLCrashReporter to nil!
    SNMLogDebug(@"[SNMCrashes] DEBUG: Cleaning up all crash files.");
    [self deleteAllFromCrashesDirectory];
    [self removeAnalyzerFile];
    [self.plCrashReporter purgePendingCrashReport];
    [self.logManager removeChannelDelegate:self forPriority:SNMPriorityHigh];
    SNMLogDebug(@"[SNMCrashes] DEBUG: Disabling crashes feature.");
  }
}

#pragma mark - SNMFeatureInternal

+ (instancetype)sharedInstance {
  static id sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (void)startFeature {
  [super startFeature];

  SNMLogVerbose(@"[SNMCrashes] VERBOSE: Started crash feature.");

  [self.logManager addChannelDelegate:self forPriority:self.priority];

  [self configureCrashReporter];

  // Get crashes from PLCrashReporter and store them in the intermediate format.
  if ([self.plCrashReporter hasPendingCrashReport]) {
    _didCrashInLastSession = YES;
    [self handleLatestCrashReport];
  }

  _crashFiles = [self persistedCrashReports];

  // Process PLCrashReports, this will format the PLCrashReport into our schena and then trigger sending.
  if (self.crashFiles.count > 0) {
    [self startDelayedCrashProcessing];
  }
}

- (NSString *)storageKey {
  return kSNMFeatureName;
}

- (SNMPriority)priority {
  return SNMPriorityHigh;
}

#pragma mark - SNMChannelDelegate

- (void)channel:(id)channel willSendLog:(id <SNMLog>)log {
  if (self.delegate && [self.delegate respondsToSelector:@selector(crashes:willSendErrorReport:)]) {
    if ([((NSObject *) log) isKindOfClass:[SNMAppleErrorLog class]]) {
      SNMErrorReport *report = [SNMErrorLogFormatter errorReportFromLog:((SNMAppleErrorLog *) log)];
      [self.delegate crashes:self willSendErrorReport:report];
    }
  }
}

- (void)channel:(id <SNMChannel>)channel didSucceedSendingLog:(id <SNMLog>)log {
  if (self.delegate && [self.delegate respondsToSelector:@selector(crashes:didSucceedSendingErrorReport:)]) {
    if ([((NSObject *) log) isKindOfClass:[SNMAppleErrorLog class]]) {
      SNMErrorReport *report = [SNMErrorLogFormatter errorReportFromLog:((SNMAppleErrorLog *) log)];
      [self.delegate crashes:self didSucceedSendingErrorReport:report];
    }
  }
}

- (void)channel:(id <SNMChannel>)channel didFailSendingLog:(id <SNMLog>)log withError:(NSError *)error {
  if (self.delegate && [self.delegate respondsToSelector:@selector(crashes:didFailSendingErrorReport:withError:)]) {
    if ([((NSObject *) log) isKindOfClass:[SNMAppleErrorLog class]]) {
      SNMErrorReport *report = [SNMErrorLogFormatter errorReportFromLog:((SNMAppleErrorLog *) log)];
      [self.delegate crashes:self didFailSendingErrorReport:report withError:error];
    }
  }
}

#pragma mark - Crash reporter configuration

- (void)configureCrashReporter {

  if (_plCrashReporter) {
    SNMLogDebug(@"[SNMCrashes] DEBUG: Already configured PLCrashReporter.");
    return;
  }

  PLCrashReporterSignalHandlerType signalHandlerType = PLCrashReporterSignalHandlerTypeBSD;
  PLCrashReporterSymbolicationStrategy symbolicationStrategy = PLCrashReporterSymbolicationStrategyNone;
  SNMPLCrashReporterConfig *config = [[SNMPLCrashReporterConfig alloc] initWithSignalHandlerType:signalHandlerType
                                                                           symbolicationStrategy:symbolicationStrategy];
  _plCrashReporter = [[SNMPLCrashReporter alloc] initWithConfiguration:config];

  /**
   The actual signal and mach handlers are only registered when invoking
   `enableCrashReporterAndReturnError`, so it is safe enough to only disable
   the following part when a debugger is attached no matter which signal
   handler type is set.
   */
  if ([SNMSonoma isDebuggerAttached]) {
    SNMLogWarning(@"[SNMCrashes] WARNING: Detecting crashes is NOT enabled due to running the app with a debugger attached.");
  } else {

    /**
     * Multiple exception handlers can be set, but we can only query the top
     * level error handler (uncaught exception handler). To check if
     * PLCrashReporter's error handler is successfully added, we compare the top
     * level one that is set before and the one after PLCrashReporter sets up
     * its own. With delayed processing we can then check if another error
     * handler was set up afterwards and can show a debug warning log message,
     * that the dev has to make sure the "newer" error handler doesn't exit the
     * process itself, because then all subsequent handlers would never be
     * invoked. Note: ANY error handler setup BEFORE SDK initialization
     * will not be processed!
     */
    NSUncaughtExceptionHandler *initialHandler = NSGetUncaughtExceptionHandler();

    NSError *error = NULL;
    [self.plCrashReporter setCrashCallbacks:&plCrashCallbacks];
    if (![self.plCrashReporter enableCrashReporterAndReturnError:&error])
      SNMLogError(@"[SNMCrashes] ERROR: Could not enable crash reporter: %@", [error localizedDescription]);
    NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();
    if (currentHandler && currentHandler != initialHandler) {
      self.exceptionHandler = currentHandler;

      SNMLogDebug(@"[SNMCrashes] DEBUG: Exception handler successfully initialized.");
    } else {
      SNMLogError(@"[SNMCrashes] ERROR: Exception handler could not be set. Make sure there is no other exception "
                      @"handler set up!");
    }
    [SNMCrashesUncaughtCXXExceptionHandlerManager addCXXExceptionHandler:uncaught_cxx_exception_handler];
  }
}

#pragma mark - Crash processing

- (void)startDelayedCrashProcessing {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startCrashProcessing) object:nil];
  [self performSelector:@selector(startCrashProcessing) withObject:nil afterDelay:0.5];
}

- (void)startCrashProcessing {
  if (![SNMCrashesHelper isAppExtension] &&
      [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
    return;
  }

  SNMLogDebug(@"[SNMCrashes] DEBUG: Start delayed CrashManager processing");

  // Was our own exception handler successfully added?
  if (self.exceptionHandler) {

    // Get the current top level error handler
    NSUncaughtExceptionHandler *currentHandler = NSGetUncaughtExceptionHandler();

    /* If the top level error handler differs from our own, then at least
     * another one was added.
     * This could cause exception crashes not to be reported to Sonoma. See
     * log message for details.
     */
    if (self.exceptionHandler != currentHandler) {
      SNMLogWarning(@"[SNMCrashes] WARNING: Another exception handler was "
                        @"added. If this invokes any kind exit() after processing "
                        @"the exception, which causes any subsequent error "
                        @"handler not to be invoked, these crashes will NOT be "
                        @"reported to Sonoma!");
    }
  }
  if (!self.sendingInProgress && self.crashFiles.count > 0) {

    // TODO: Send and clean next crash report
    [self processCrashReport];
  }
}

- (void)processCrashReport {
  NSError *error = NULL;
  _unprocessedLogs = [[NSMutableArray alloc] init];
  _unprocessedReports = [[NSMutableArray alloc] init];
  _unprocessedFilePaths = [[NSMutableArray alloc] init];

  NSArray *tempCrashesFiles = [NSArray arrayWithArray:self.crashFiles];
  for (NSString *filePath in tempCrashesFiles) {

    // we start sending always with the oldest pending one
    NSData *crashFileData = [NSData dataWithContentsOfFile:filePath];
    if ([crashFileData length] > 0) {
      SNMLogVerbose(@"[SNMCrashes] VERBOSE: Crash report found");
      if (self.isEnabled) {
        SNMPLCrashReport *report = [[SNMPLCrashReport alloc] initWithData:crashFileData error:&error];
        SNMAppleErrorLog *log = [SNMErrorLogFormatter errorLogFromCrashReport:report];
        SNMErrorReport *errorReport = [SNMErrorLogFormatter errorReportFromLog:((SNMAppleErrorLog *) log)];
        if ([self.delegate crashes:self shouldProcessErrorReport:errorReport]) {
          SNMLogDebug(@"[SNMCrashes] DEBUG: shouldProcessErrorReport returned true, processing the crash report: %@",
                      report.debugDescription);

          // Put the log to temporary space for next callbacks.
          [_unprocessedLogs addObject:log];
          [_unprocessedReports addObject:errorReport];
          [_unprocessedFilePaths addObject:filePath];
          continue;
        } else {
          SNMLogDebug(@"[SNMCrashes] DEBUG: shouldProcessErrorReport returned false, discard the crash report: %@",
                      report.debugDescription);
        }
      } else {
        SNMLogDebug(@"[SNMCrashes] DEBUG: Crashes feature is disabled, discard the crash report");
      }

      // Clean up files.
      [self deleteCrashReportWithFilePath:filePath];
      [self.crashFiles removeObject:filePath];
    }
  }

  // Get a user confirmation if there are crash logs that need to be processed.
  if ([_unprocessedLogs count] > 0) {
    NSNumber *flag = [kSNMUserDefaults objectForKey:kSNMUserConfirmationKey];
    if (flag && [flag boolValue]) {

      // User confirmation is set to SNMUserConfirmationAlways.
      SNMLogDebug(@"The flag for user confirmation is set to SNMUserConfirmationAlways, continue sending logs");
      [SNMCrashes notifyWithUserConfirmation:SNMUserConfirmationSend];
      return;
    } else if (!_userConfirmationHandler || !_userConfirmationHandler(_unprocessedReports)) {

      // User confirmation handler doesn't exist or returned NO which means 'want to process'.
      SNMLogDebug(@"The user confirmation handler is not implemented or returned NO, continue sending logs");
      [SNMCrashes notifyWithUserConfirmation:SNMUserConfirmationSend];
    }
  }
}

#pragma mark - Helper

- (void)deleteAllFromCrashesDirectory {
  NSError *error = nil;
  for (NSString *filePath in [self.fileManager enumeratorAtPath:self.crashesDir]) {
    NSString *path = [self.crashesDir stringByAppendingPathComponent:filePath];
    [_fileManager removeItemAtPath:path error:&error];

    if (error) {
      SNMLogError(@"[SNMCrashes] ERROR: Error deleting file %@: %@", filePath, error.localizedDescription);
    }
  }
  [self.crashFiles removeAllObjects];
}

- (void)deleteCrashReportWithFilePath:(NSString *)filePath {
  NSError *error = NULL;
  if ([self.fileManager fileExistsAtPath:filePath]) {
    [self.fileManager removeItemAtPath:filePath error:&error];
  }
}

- (void)handleLatestCrashReport {
  NSError *error = NULL;

  // Check if the next call ran successfully the last time
  if (![self.fileManager fileExistsAtPath:self.analyzerInProgressFile]) {

    // Mark the start of the routine
    [self createAnalyzerFile];

    // Try loading the crash report
    NSData *crashData =
        [[NSData alloc] initWithData:[self.plCrashReporter loadPendingCrashReportDataAndReturnError:&error]];
    NSString *cacheFilename = [NSString stringWithFormat:@"%.0f", [NSDate timeIntervalSinceReferenceDate]];

    if (crashData == nil) {
      SNMLogError(@"[SNMCrashes] ERROR: Could not load crash report: %@", error);
    } else {

      // Get data of PLCrashReport and write it to SDK directory
      SNMPLCrashReport *report = [[SNMPLCrashReport alloc] initWithData:crashData error:&error];

      if (report) {
        [crashData writeToFile:[self.crashesDir stringByAppendingPathComponent:cacheFilename] atomically:YES];
        _lastSessionCrashReport = [SNMErrorLogFormatter errorReportFromCrashReport:report];
      } else {
        SNMLogWarning(@"[SNMCrashes] WARNING: Could not parse crash report");
      }
    }

    // Purge the report mark at the end of the routine
    [self removeAnalyzerFile];
  }

  [self.plCrashReporter purgePendingCrashReport];
}

- (NSMutableArray *)persistedCrashReports {
  NSMutableArray *persitedCrashReports = [NSMutableArray new];
  if ([self.fileManager fileExistsAtPath:self.crashesDir]) {
    NSError *error;
    NSArray *dirArray = [self.fileManager contentsOfDirectoryAtPath:self.crashesDir error:&error];

    for (NSString *file in dirArray) {
      NSString *filePath = [self.crashesDir stringByAppendingPathComponent:file];
      NSDictionary *fileAttributes = [self.fileManager attributesOfItemAtPath:filePath error:&error];

      if ([[fileAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular] &&
          [[fileAttributes objectForKey:NSFileSize] intValue] > 0 && ![file hasSuffix:@".DS_Store"] &&
          ![file hasSuffix:@".analyzer"] && ![file hasSuffix:@".plist"] && ![file hasSuffix:@".data"] &&
          ![file hasSuffix:@".meta"] && ![file hasSuffix:@".desc"]) {
        [persitedCrashReports addObject:filePath];
      }
    }
  }
  return persitedCrashReports;
}

- (void)removeAnalyzerFile {
  if ([self.fileManager fileExistsAtPath:self.analyzerInProgressFile]) {
    NSError *error = nil;
    if (![self.fileManager removeItemAtPath:self.analyzerInProgressFile error:&error]) {
      SNMLogError(@"[SNMCrashes] ERROR: Couldn't remove analyzer file at %@: ", self.analyzerInProgressFile);
    }
  }
}

- (void)createAnalyzerFile {
  if (![self.fileManager fileExistsAtPath:self.analyzerInProgressFile]) {
    [self.fileManager createFileAtPath:self.analyzerInProgressFile contents:nil attributes:nil];
  }
}

@end
