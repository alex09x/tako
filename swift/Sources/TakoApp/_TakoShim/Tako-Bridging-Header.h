// Upstream's Xcode target uses an Objective-C bridging header, which makes
// Cocoa's types visible to every Swift file in the module without a
// per-file `import`. Several of their sources rely on that -- for example
// Helpers/ExpiringUndoManager.swift subclasses UndoManager with no import
// of its own. Keeping the same header lets their files stay verbatim.

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

// Objective-C helpers upstream's Swift calls directly.
#import "TakoObjC.h"
