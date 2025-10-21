#import <Foundation/Foundation.h>

@class RNVoskModel;

NS_ASSUME_NONNULL_BEGIN

@interface RNVoskModelCache : NSObject

+ (instancetype)sharedCache;

/// Returns a cached model if available or loads it from disk. Path accepts optional file:// prefix.
- (nullable RNVoskModel *)acquireModelAtPath:(NSString *)path error:(NSError **)error;

/// Moves the current active model into the cache when keepCached is YES. When NO, the active
/// model is closed and removed.
- (void)releaseActiveKeepingCache:(BOOL)keepCached;

/// Clears both the active and cached models, closing their underlying resources.
- (void)clear;

/// Gives read-only access to the path of the active model for diagnostics.
- (nullable NSString *)activePath;

@end

NS_ASSUME_NONNULL_END
