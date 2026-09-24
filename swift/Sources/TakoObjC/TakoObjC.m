#import "TakoObjC.h"

BOOL TakoAddTabbedWindowSafely(NSWindow *parent,
                                  NSWindow *child,
                                  NSInteger ordered,
                                  NSError *_Nullable *_Nullable error) {
    @try {
        [parent addTabbedWindow:child ordered:(NSWindowOrderingMode)ordered];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.tako.tabbing"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"addTabbedWindow raised"
            }];
        }
        return NO;
    }
}


@implementation VibrantLayer

/// The real class comes from AppKit at runtime; this stands in so the app
/// still draws (opaque instead of vibrant) when it is unavailable.
- (nullable instancetype)initForAppearance:(VibrantLayerAppearance)appearance {
    return [self init];
}

@end
