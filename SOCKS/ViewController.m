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
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <net/if_dl.h>
#include "hev-main.h"

@interface ViewController ()
@end

@implementation ViewController

static ViewController *sharedInstance = nil;

#define MAX_LOG_LINES 1000

// Interface traffic tracking
static NSString *activeInterface = nil;
static uint64_t baselineRxBytes  = 0;
static uint64_t baselineTxBytes  = 0;
static uint64_t lastRxBytes      = 0;
static uint64_t lastTxBytes      = 0;
static NSDate  *lastStatsTime    = nil;

// Active connections counter (parsed from HEV log)
static int activeConnections = 0;

// Log file offset for tailing
static long long logFileOffset = 0;

// ─────────────────────────────────────────────
#pragma mark - Helpers

/// Read raw byte counters for a named network interface (AF_LINK level).
static BOOL getInterfaceBytes(const char *ifname, uint64_t *rxBytes, uint64_t *txBytes) {
    struct ifaddrs *addrs;
    if (getifaddrs(&addrs) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *a = addrs; a != NULL; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_LINK) continue;
        if (strcmp(a->ifa_name, ifname) != 0) continue;
        if (!a->ifa_data) continue;
        struct if_data *d = (struct if_data *)a->ifa_data;
        *rxBytes = d->ifi_ibytes;
        *txBytes = d->ifi_obytes;
        found = YES;
        break;
    }
    freeifaddrs(addrs);
    return found;
}

static NSString *getInterfaceNameForIPv4Address(NSString *ipAddress) {
    if (!ipAddress.length) return nil;

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return nil;

    NSString *foundInterface = nil;
    for (struct ifaddrs *a = addrs; a != NULL; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP) || !(a->ifa_flags & IFF_RUNNING)) continue;

        char addrBuf[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *sin = (const struct sockaddr_in *)a->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, addrBuf, sizeof(addrBuf))) continue;

        NSString *candidate = [NSString stringWithUTF8String:addrBuf];
        if (![candidate isEqualToString:ipAddress]) continue;

        foundInterface = [NSString stringWithUTF8String:a->ifa_name];
        break;
    }

    freeifaddrs(addrs);
    return foundInterface;
}

- (NSString *)formatBytes:(uint64_t)bytes {
    if (bytes < 1024)            return [NSString stringWithFormat:@"%llu B",   bytes];
    if (bytes < 1024*1024)       return [NSString stringWithFormat:@"%.1f KB",  bytes/1024.0];
    if (bytes < 1024*1024*1024)  return [NSString stringWithFormat:@"%.1f MB",  bytes/(1024.0*1024.0)];
    return                              [NSString stringWithFormat:@"%.1f GB",   bytes/(1024.0*1024.0*1024.0)];
}

- (NSString *)formatSpeed:(double)bps {
    if (bps < 1024)            return [NSString stringWithFormat:@"%.0f B/s",  bps];
    if (bps < 1024*1024)       return [NSString stringWithFormat:@"%.1f KB/s", bps/1024.0];
    if (bps < 1024*1024*1024)  return [NSString stringWithFormat:@"%.1f MB/s", bps/(1024.0*1024.0)];
    return                            [NSString stringWithFormat:@"%.1f GB/s", bps/(1024.0*1024.0*1024.0)];
}

// ─────────────────────────────────────────────
#pragma mark - Stats timer (1 s)

- (void)updateStatsDisplay {
    if (!activeInterface) return;

    uint64_t rxBytes = 0, txBytes = 0;
    if (!getInterfaceBytes([activeInterface UTF8String], &rxBytes, &txBytes)) return;

    // Bytes since server start
    uint64_t totalDown = rxBytes > baselineRxBytes ? rxBytes - baselineRxBytes : 0;
    uint64_t totalUp   = txBytes > baselineTxBytes ? txBytes - baselineTxBytes : 0;

    NSDate *now = [NSDate date];
    NSTimeInterval elapsed = lastStatsTime ? [now timeIntervalSinceDate:lastStatsTime] : 1.0;

    double downSpeed = 0, upSpeed = 0;
    if (elapsed > 0 && lastStatsTime) {
        downSpeed = (double)(rxBytes > lastRxBytes ? rxBytes - lastRxBytes : 0) / elapsed;
        upSpeed   = (double)(txBytes > lastTxBytes ? txBytes - lastTxBytes : 0) / elapsed;
    }

    lastRxBytes   = rxBytes;
    lastTxBytes   = txBytes;
    lastStatsTime = now;

    NSString *stats = [NSString stringWithFormat:
        @"↓ %@ (%@)  ↑ %@ (%@)  | %d conn",
        [self formatBytes:totalDown], [self formatSpeed:downSpeed],
        [self formatBytes:totalUp],   [self formatSpeed:upSpeed],
        activeConnections];
    self.statsLabel.text = stats;
}

// ─────────────────────────────────────────────
#pragma mark - HEV log file tailing (0.5 s)

- (void)startLogFileMonitoring:(NSString *)logPath {
    logFileOffset = 0;

    // Create the file so HEV can open it immediately
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
        (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:logPath];
        if (!fh) return;
        [fh seekToFileOffset:(unsigned long long)logFileOffset];
        NSData *data = [fh readDataToEndOfFile];
        logFileOffset = (long long)[fh offsetInFile];
        [fh closeFile];

        if (!data.length) return;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return;

        for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if (!line.length) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self logFromHev:line];
            });
        }
    });
    dispatch_resume(timer);
}

/// Format a raw HEV log line and feed it to the UI log.
- (void)logFromHev:(NSString *)line {
    // HEV format examples:
    //   "I hev-socks5-session.c:56: [Session/0x...] connect 1.2.3.4:443"
    //   "W hev-socks5-session.c:89: [Session/0x...] connect failed"
    //   "E hev-socks5-server.c:12: ..."
    NSString *levelPrefix = @"";
    NSString *body = line;

    if (line.length >= 2) {
        unichar first = [line characterAtIndex:0];
        if ([line characterAtIndex:1] == ' ') {
            if      (first == 'I') { levelPrefix = @"[HEV]"; }
            else if (first == 'W') { levelPrefix = @"[WARN]"; }
            else if (first == 'E') { levelPrefix = @"[ERROR]"; }
            else if (first == 'D') { levelPrefix = @"[DEBUG]"; }

            if (levelPrefix.length) {
                // Strip the leading "X " prefix
                body = [line substringFromIndex:2];

                // Strip the source-file:lineno: part if present
                // e.g. "hev-socks5-session.c:56: [Session...]"
                NSRange colon2 = [body rangeOfString:@": "];
                if (colon2.location != NSNotFound) {
                    body = [body substringFromIndex:colon2.location + 2];
                }
            }
        }
    }

    NSString *formatted = levelPrefix.length
        ? [NSString stringWithFormat:@"%@ %@", levelPrefix, body]
        : line;

    // Update active-connections counter heuristically
    NSString *lower = formatted.lowercaseString;
    if ([lower containsString:@"connect"] &&
        ![lower containsString:@"failed"] &&
        ![lower containsString:@"close"]) {
        activeConnections++;
    } else if ([lower containsString:@"close"] ||
               [lower containsString:@"destroy"] ||
               [lower containsString:@"disconnect"]) {
        if (activeConnections > 0) activeConnections--;
    }

    [self logMessage:formatted];
}

// ─────────────────────────────────────────────
#pragma mark - Logging

- (void)logMessage:(NSString *)message {
    NSLog(@"%@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [NSDateFormatter
            localizedStringFromDate:[NSDate date]
                          dateStyle:NSDateFormatterNoStyle
                          timeStyle:NSDateFormatterMediumStyle];

        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];

        // Gray timestamp
        [attr appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"[%@] ", timestamp]
                attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}]];

        // Colored message
        NSString *lower = message.lowercaseString;
        UIColor *color;
        if ([lower containsString:@"error"] || [lower containsString:@"failed"] ||
            [lower containsString:@"fail"])                                          { color = [UIColor redColor]; }
        else if ([lower containsString:@"connect"] &&
                 ![lower containsString:@"failed"])                                  { color = [UIColor greenColor]; }
        else if ([lower containsString:@"close"] ||
                 [lower containsString:@"disconnect"] ||
                 [lower containsString:@"destroy"])                                  { color = [UIColor orangeColor]; }
        else if ([lower containsString:@"warn"])                                     { color = [UIColor yellowColor]; }
        else                                                                         { color = [UIColor whiteColor]; }

        [attr appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n", message]
                attributes:@{NSForegroundColorAttributeName: color}]];

        NSMutableAttributedString *current = [[NSMutableAttributedString alloc]
            initWithAttributedString:self.logTextView.attributedText
                ?: [[NSAttributedString alloc] init]];
        [current appendAttributedString:attr];

        // Font for entire buffer
        [current addAttribute:NSFontAttributeName
                        value:[UIFont fontWithName:@"Menlo-Regular" size:9.0]
                        range:NSMakeRange(0, current.length)];

        // Trim to MAX_LOG_LINES
        NSArray *lines = [current.string componentsSeparatedByString:@"\n"];
        if ((NSInteger)lines.count > MAX_LOG_LINES) {
            NSUInteger excess = lines.count - MAX_LOG_LINES;
            NSString *prefix = [[lines subarrayWithRange:NSMakeRange(0, excess)]
                                    componentsJoinedByString:@"\n"];
            NSRange r = [current.string rangeOfString:prefix];
            if (r.location != NSNotFound)
                [current deleteCharactersInRange:NSMakeRange(r.location, r.length + 1)];
        }

        self.logTextView.attributedText = current;
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    });
}

+ (void)logMessage:(NSString *)message {
    if (sharedInstance) [sharedInstance logMessage:message];
    else                 NSLog(@"%@", message);
}

+ (void)logFromC:(const char *)message {
    if (message) [ViewController logMessage:[NSString stringWithUTF8String:message]];
}

+ (void)logConnection:(NSString *)clientIP port:(int)clientPort {
    [ViewController logMessage:[NSString stringWithFormat:
        @"[SOCKS] New connection from %@:%d", clientIP, clientPort]];
}

+ (void)logDisconnection:(NSString *)clientIP port:(int)clientPort {
    [ViewController logMessage:[NSString stringWithFormat:
        @"[SOCKS] Client disconnected %@:%d", clientIP, clientPort]];
}

// Legacy — not called with HEV but kept for API compatibility
+ (void)updateTrafficStats:(uint64_t)uploadBytes downloadBytes:(uint64_t)downloadBytes {}

// ─────────────────────────────────────────────
#pragma mark - View lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    sharedInstance = self;

    // Log text view appearance
    self.logTextView.font                 = [UIFont fontWithName:@"Menlo-Regular" size:9.0];
    self.logTextView.textContainerInset   = UIEdgeInsetsMake(10, 10, 10, 10);
    self.logTextView.layer.cornerRadius   = 8.0;
    self.logTextView.layer.borderWidth    = 1.0;
    self.logTextView.layer.borderColor    = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    self.logTextView.backgroundColor      = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0];
    self.logTextView.attributedText       = [[NSAttributedString alloc] init];

    [self logMessage:@"[SOCKS] View controller loaded"];

    int port = 9876;
    [self logMessage:[NSString stringWithFormat:@"[SOCKS] Initializing SOCKS5 server on port %d", port]];

    // ── Start proxy server ──────────────────────────────────────
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *ipAddress = [AppDelegate deviceIPAddress];
        if ([ipAddress isEqualToString:@"127.0.0.1"]) {
            [self logMessage:@"[SOCKS] No network interface found"];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"No Network Interface"
                                     message:@"Please enable Personal Hotspot in Settings and try again."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction
                    actionWithTitle:@"OK"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
                    [self.statusLabel setText:@"Not Running - No Network Interface"];
                    [self.audioPlayer stop];
                    [[AVAudioSession sharedInstance] setActive:NO error:nil];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            });
            return;
        }

        NSString *ifName = getInterfaceNameForIPv4Address(ipAddress);
        if (!ifName.length) {
            ifName = @"en0";
            [self logMessage:[NSString stringWithFormat:
                @"[SOCKS] Could not map IP %@ to interface, fallback to %@", ipAddress, ifName]];
        }
        activeInterface = ifName;

        // Snapshot baseline bytes so stats reflect only traffic since launch
        uint64_t rx0 = 0, tx0 = 0;
        getInterfaceBytes([activeInterface UTF8String], &rx0, &tx0);
        baselineRxBytes = rx0;  baselineTxBytes = tx0;
        lastRxBytes     = rx0;  lastTxBytes     = tx0;
        lastStatsTime   = [NSDate date];

        [self logMessage:[NSString stringWithFormat:
            @"[SOCKS] Starting HEV SOCKS5 server on %@ (%@:%d)", activeInterface, ipAddress, port]];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.statusLabel setText:[NSString stringWithFormat:@"Running at %@:%d", ipAddress, port]];
        });

        // Log file for HEV output → tail it for connection events
        NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hev-socks5.log"];
        [self logMessage:[NSString stringWithFormat:@"[SOCKS] HEV log → %@", logPath]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startLogFileMonitoring:logPath];
        });

        // Build YAML config
        NSString *yamlConfig = [NSString stringWithFormat:
            @"main:\n"
             "  workers: 4\n"
             "  port: %d\n"
             "  listen-address: '0.0.0.0'\n"
             "misc:\n"
             "  log-file: '%@'\n"
             "  log-level: info\n",
            port, logPath];

        const char *cfgStr = [yamlConfig UTF8String];
        int status = hev_socks5_server_main_from_str(
            (const unsigned char *)cfgStr, (unsigned int)strlen(cfgStr));

        [self logMessage:[NSString stringWithFormat:
            @"[SOCKS] Server exited with status %d", status]];
        dispatch_async(dispatch_get_main_queue(), ^{
            activeInterface = nil;
            activeConnections = 0;
            [self.statusLabel setText:[NSString stringWithFormat:@"Stopped (exit %d)", status]];
        });
    });

    // ── Background audio (keeps app alive) ─────────────────────
    [self logMessage:@"[SOCKS] Setting up background audio"];
    NSURL *audioURL = [NSURL fileURLWithPath:
        [[NSBundle mainBundle] pathForResource:@"blank" ofType:@"wav"]];
    if (audioURL) {
        NSError *err = nil;
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:audioURL error:&err];
        if (err) {
            [self logMessage:[NSString stringWithFormat:
                @"[SOCKS] Audio player error: %@", err.localizedDescription]];
        } else {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                                   error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            self.audioPlayer.volume        = 0.01;
            self.audioPlayer.numberOfLoops = -1;
            [self.audioPlayer prepareToPlay];
            BOOL ok = [self.audioPlayer play];
            [self logMessage:[NSString stringWithFormat:
                @"[SOCKS] Background audio %@", ok ? @"started" : @"failed to start"]];
        }
    } else {
        [self logMessage:@"[SOCKS] blank.wav not found"];
    }

    // ── Stats timer ─────────────────────────────────────────────
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(updateStatsDisplay)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self logMessage:@"[SOCKS] Memory warning"];
}

@end
