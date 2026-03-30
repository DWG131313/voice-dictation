#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions that Swift cannot handle.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
