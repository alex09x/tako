#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A private AppKit CALayer subclass that renders vibrant (appearance-aware)
/// content. Upstream declares it the same way, since it has no public header.
typedef NS_ENUM(NSInteger, VibrantLayerAppearance) {
    VibrantLayerAppearanceLight = 0,
    VibrantLayerAppearanceDark = 1,
};

@interface VibrantLayer : CALayer
- (nullable instancetype)initForAppearance:(VibrantLayerAppearance)appearance
    NS_SWIFT_NAME(init(forAppearance:));
@end

/// AppKit raises NSExceptions from `addTabbedWindow:ordered:` in some visual
/// tab-picker flows. Swift cannot recover from those, so the call is made
/// from Objective-C, where it can be caught and reported as an NSError.
BOOL TakoAddTabbedWindowSafely(NSWindow *parent,
                                  NSWindow *child,
                                  NSInteger ordered,
                                  NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
