//
//  ViewController.m
//  SOCKS
//
//  Created by Robert Xiao on 8/19/18.
//  Copyright © 2018 Robert Xiao. All rights reserved.
//

#import "ViewController.h"
#import "AppDelegate.h"
#include <stdio.h>
#include <unistd.h>
#include <stdarg.h>
#include <pthread.h>

@interface ViewController ()

@end

@implementation ViewController

extern int socks_main(int argc, const char** argv);
extern void custom_log(const char *format, ...);
extern void update_traffic_stats_ui(uint64_t uploadBytes, uint64_t downloadBytes);
static ViewController *sharedInstance = nil;

#define MAX_LOG_LINES 1000

static uint64_t lastUploadBytes = 0;
static uint64_t lastDownloadBytes = 0;
static NSDate *lastUpdateTime = nil;
static NSTimer *statsUpdateTimer;
static uint64_t pending_upload_bytes = 0;
static uint64_t pending_download_bytes = 0;
static pthread_mutex_t pending_stats_mutex = PTHREAD_MUTEX_INITIALIZER;

- (NSString *)formatBytes:(uint64_t)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes/1024.0];
    if (bytes < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes/(1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.1f GB", bytes/(1024.0*1024.0*1024.0)];
}

- (NSString *)formatSpeed:(double)bytesPerSecond {
    if (bytesPerSecond < 1024) return [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond];
    if (bytesPerSecond < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB/s", bytesPerSecond/1024.0];
    if (bytesPerSecond < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB/s", bytesPerSecond/(1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.1f GB/s", bytesPerSecond/(1024.0*1024.0*1024.0)];
}

+ (void)updateTrafficStats:(uint64_t)uploadBytes downloadBytes:(uint64_t)downloadBytes {
    if (sharedInstance) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [sharedInstance updateStatsWithUpload:uploadBytes download:downloadBytes];
        });
    }
}

- (void)updateStatsWithUpload:(uint64_t)uploadBytes download:(uint64_t)downloadBytes {
    NSDate *now = [NSDate date];
    NSTimeInterval elapsed = [now timeIntervalSinceDate:lastUpdateTime ?: now];
    
    if (lastUpdateTime && elapsed > 0) {
        double uploadSpeed = (uploadBytes - lastUploadBytes) / elapsed;
        double downloadSpeed = (downloadBytes - lastDownloadBytes) / elapsed;
        
        NSString *stats = [NSString stringWithFormat:@"↑ %@ (%@) ↓ %@ (%@)", 
            [self formatBytes:uploadBytes],
            [self formatSpeed:uploadSpeed],
            [self formatBytes:downloadBytes],
            [self formatSpeed:downloadSpeed]];
            
        self.statsLabel.text = stats;
    }
    
    lastUploadBytes = uploadBytes;
    lastDownloadBytes = downloadBytes;
    lastUpdateTime = now;
}

void update_traffic_stats_ui(uint64_t uploadBytes, uint64_t downloadBytes) {
    pthread_mutex_lock(&pending_stats_mutex);
    pending_upload_bytes = uploadBytes;
    pending_download_bytes = downloadBytes;
    pthread_mutex_unlock(&pending_stats_mutex);
}
void custom_log(const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    
    [ViewController logFromC:buffer];
    // Also write to stderr for Xcode console
    fprintf(stderr, "%s\n", buffer);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    sharedInstance = self;
    
    // Configure log text view
    self.logTextView.font = [UIFont fontWithName:@"Menlo-Regular" size:9.0];
    self.logTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.logTextView.layer.cornerRadius = 8.0;
    self.logTextView.layer.borderWidth = 1.0;
    self.logTextView.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    self.logTextView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0];
    
    // Enable attributed text
    self.logTextView.attributedText = [[NSAttributedString alloc] init];
    
    freopen("/dev/null", "w", stdout);
    dup2(STDOUT_FILENO, STDERR_FILENO);
    
    [self logMessage:@"[SOCKS] View controller loaded"];

    int port = 9876;
    [self logMessage:[NSString stringWithFormat:@"[SOCKS] Initializing SOCKS server on port %d", port]];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char portbuf[32];
        sprintf(portbuf, "%d", port);
        const char *argv[] = {"microsocks", "-p", portbuf, NULL};
        
        NSString *ipAddress = [AppDelegate deviceIPAddress];
        if ([ipAddress isEqualToString:@"127.0.0.1"]) {
            [self logMessage:@"[SOCKS] No matching interface found, using fallback IP address"];
            [self logMessage:@"[SOCKS] Stopping server due to no valid interface"];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Network Interface"
                                                                             message:@"Please enable Personal Hotspot in Settings and try again."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                                               handler:^(UIAlertAction * action) {
                    [self.statusLabel setText:@"Not Running - No Network Interface"];
                    [self.audioPlayer stop];
                    [[AVAudioSession sharedInstance] setActive:NO error:nil];
                    [[UIApplication sharedApplication] performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
                }];
                [alert addAction:okAction];
                [self presentViewController:alert animated:YES completion:nil];
            });
            return;
        }
        [self logMessage:[NSString stringWithFormat:@"[SOCKS] Starting server at %@:%d", ipAddress, port]];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.statusLabel setText:[NSString stringWithFormat:@"Running at %@:%d", ipAddress, port]];
        });
        
        int status = socks_main(3, argv);
        [self logMessage:[NSString stringWithFormat:@"[SOCKS] Server exited with status: %d", status]];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.statusLabel setText:[NSString stringWithFormat:@"Failed to start: %d", status]];
        });
    });
    
    [self logMessage:@"[SOCKS] Setting up background audio"];
    NSURL *url = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"blank" ofType:@"wav"]];
    if (url) {
        NSError *error = nil;
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
        if (error) {
            [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error creating audio player: %@", error.localizedDescription]];
        } else {
            [self logMessage:@"[SOCKS] Successfully created audio player"];
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback 
                                           withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                                                 error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error setting audio session category: %@", error.localizedDescription]];
            }
            
            [[AVAudioSession sharedInstance] setActive:YES error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error activating audio session: %@", error.localizedDescription]];
            }
            
            [self.audioPlayer setVolume:0.01];
            [self.audioPlayer setNumberOfLoops:-1];
            [self.audioPlayer prepareToPlay];
            BOOL playSuccess = [self.audioPlayer play];
            [self logMessage:[NSString stringWithFormat:@"[SOCKS] Background audio %@ start", playSuccess ? @"did" : @"failed to"]];
        }
    } else {
        [self logMessage:@"[SOCKS] Error: Could not find blank.wav resource"];
    }
    
    // Add stats update timer
    statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateStatsDisplay)
                                                    userInfo:nil
                                                     repeats:YES];
    
    // 確保初始文本也使用正確的字體
    NSMutableAttributedString *initialText = [[NSMutableAttributedString alloc] initWithString:@""];
    [initialText addAttribute:NSFontAttributeName 
                       value:[UIFont fontWithName:@"Menlo-Regular" size:9.0] 
                       range:NSMakeRange(0, 0)];
    self.logTextView.attributedText = initialText;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self logMessage:@"[SOCKS] Received memory warning"];
}

- (void)logMessage:(NSString *)message {
    NSLog(@"%@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date] 
                                                          dateStyle:NSDateFormatterNoStyle 
                                                          timeStyle:NSDateFormatterMediumStyle];
        
        NSMutableAttributedString *attributedMessage = [[NSMutableAttributedString alloc] init];
        
        // Timestamp in gray
        NSAttributedString *timeString = [[NSAttributedString alloc] 
            initWithString:[NSString stringWithFormat:@"[%@]", timestamp]
            attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}];
        [attributedMessage appendAttributedString:timeString];
        
        // Message with color based on content
        UIColor *messageColor;
        if ([message containsString:@"Error"] || [message containsString:@"Failed"] || [message containsString:@"failed"]) {
            messageColor = [UIColor redColor];
        } else if ([message containsString:@"connected"] || [message containsString:@"Successfully"]) {
            messageColor = [UIColor greenColor];
        } else if ([message containsString:@"disconnected"]) {
            messageColor = [UIColor orangeColor];
        } else {
            messageColor = [UIColor whiteColor];
        }
        
        NSAttributedString *contentString = [[NSAttributedString alloc] 
            initWithString:[NSString stringWithFormat:@"%@\n", message]
            attributes:@{NSForegroundColorAttributeName: messageColor}];
        [attributedMessage appendAttributedString:contentString];
        
        NSMutableAttributedString *currentText = [[NSMutableAttributedString alloc] 
            initWithAttributedString:self.logTextView.attributedText ?: [[NSAttributedString alloc] init]];
        [currentText appendAttributedString:attributedMessage];
        
        // 為整個文本設置字體
        [currentText addAttribute:NSFontAttributeName 
                           value:[UIFont fontWithName:@"Menlo-Regular" size:9.0] 
                           range:NSMakeRange(0, currentText.length)];
        
        // 檢查並限制行數
        NSArray *lines = [currentText.string componentsSeparatedByString:@"\n"];
        if (lines.count > MAX_LOG_LINES) {
            NSRange deleteRange = [currentText.string rangeOfString:
                [[lines subarrayWithRange:NSMakeRange(0, lines.count - MAX_LOG_LINES)] componentsJoinedByString:@"\n"]];
            [currentText deleteCharactersInRange:deleteRange];
        }
        
        self.logTextView.attributedText = currentText;
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    });
}

+ (void)logMessage:(NSString *)message {
    if (sharedInstance) {
        [sharedInstance logMessage:message];
    } else {
        NSLog(@"%@", message);
    }
}

+ (void)logFromC:(const char *)message {
    if (message) {
        NSString *nsMessage = [NSString stringWithUTF8String:message];
        [ViewController logMessage:nsMessage];
    }
}

+ (void)logConnection:(NSString *)clientIP port:(int)clientPort {
    NSString *message = [NSString stringWithFormat:@"[SOCKS] New connection from %@:%d", clientIP, clientPort];
    [ViewController logMessage:message];
}

+ (void)logDisconnection:(NSString *)clientIP port:(int)clientPort {
    NSString *message = [NSString stringWithFormat:@"[SOCKS] Client disconnected %@:%d", clientIP, clientPort];
    [ViewController logMessage:message];
}

- (void)updateStatsDisplay {
    pthread_mutex_lock(&pending_stats_mutex);
    uint64_t uploadBytes = pending_upload_bytes;
    uint64_t downloadBytes = pending_download_bytes;
    pthread_mutex_unlock(&pending_stats_mutex);
    
    [self updateStatsWithUpload:uploadBytes download:downloadBytes];
}

@end
