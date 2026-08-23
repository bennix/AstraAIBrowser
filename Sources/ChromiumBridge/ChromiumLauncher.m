// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import "ChromiumLauncher.h"

@implementation ChromiumLauncher

+ (instancetype)sharedInstance {
    static ChromiumLauncher *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ChromiumLauncher alloc] init];
    });
    return sharedInstance;
}

@end
