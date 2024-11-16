//
//  ViewController.h
//  SOCKS
//
//  Created by Robert Xiao on 8/19/18.
//  Copyright © 2018 Robert Xiao. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface ViewController : UIViewController

@property (weak, nonatomic) IBOutlet UILabel *statusLabel;
@property (weak, nonatomic) IBOutlet UILabel *statsLabel;
@property (strong) AVAudioPlayer *audioPlayer;
@property (weak, nonatomic) IBOutlet UITextView *logTextView;

+ (void)logMessage:(NSString *)message;
- (void)logMessage:(NSString *)message;
+ (void)logFromC:(const char *)message;
+ (void)logConnection:(NSString *)clientIP port:(int)clientPort;
+ (void)logDisconnection:(NSString *)clientIP port:(int)clientPort;
+ (void)updateTrafficStats:(uint64_t)uploadBytes downloadBytes:(uint64_t)downloadBytes;
- (void)updateStatsDisplay;

@end

