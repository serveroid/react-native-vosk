#import "RNVoskModelCache.h"

#import "RNVoskModel.h"

@interface RNVoskModelCacheEntry : NSObject
@property(nonatomic, strong) RNVoskModel *model;
@property(nonatomic, copy) NSString *path;
@end

@implementation RNVoskModelCacheEntry
+ (instancetype)entryWithModel:(RNVoskModel *)model path:(NSString *)path {
  RNVoskModelCacheEntry *entry = [RNVoskModelCacheEntry new];
  entry.model = model;
  entry.path = path;
  return entry;
}
@end

@interface RNVoskModelCache ()
@property(nonatomic, strong, nullable) RNVoskModelCacheEntry *active;
@property(nonatomic, strong, nullable) RNVoskModelCacheEntry *cached;
@end

@implementation RNVoskModelCache

+ (instancetype)sharedCache {
  static RNVoskModelCache *cache = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ cache = [RNVoskModelCache new]; });
  return cache;
}

- (NSString *)normalizePath:(NSString *)path {
  if ([path hasPrefix:@"file://"]) {
    return [path substringFromIndex:7];
  }
  return path;
}

- (nullable NSString *)activePath {
  @synchronized(self) {
    return self.active.path;
  }
}

- (nullable RNVoskModel *)acquireModelAtPath:(NSString *)path error:(NSError **)error {
  NSString *normalized = [self normalizePath:path];
  @synchronized(self) {
    if (self.active && [self.active.path isEqualToString:normalized]) {
      return self.active.model;
    }
    if (self.cached && [self.cached.path isEqualToString:normalized]) {
      RNVoskModelCacheEntry *previousActive = self.active;
      self.active = self.cached;
      self.cached = previousActive;
      return self.active.model;
    }
  }

  NSError *localError = nil;
  RNVoskModel *model = [[RNVoskModel alloc] initWithName:normalized error:&localError];
  if (!model) {
    if (error) {
      *error = localError;
    }
    return nil;
  }

  @synchronized(self) {
    if (self.active) {
      if (self.cached && self.cached.model != self.active.model) {
        self.cached = nil;
      }
      self.cached = self.active;
    }
    self.active = [RNVoskModelCacheEntry entryWithModel:model path:normalized];
  }

  return model;
}

- (void)releaseActiveKeepingCache:(BOOL)keepCached {
  @synchronized(self) {
    if (!self.active) {
      return;
    }
    if (keepCached) {
      if (self.cached && self.cached.model != self.active.model) {
        self.cached = nil; // dealloc closes previous cached
      }
      self.cached = self.active;
    }
    self.active = nil;
  }
}

- (void)clear {
  @synchronized(self) {
    self.active = nil;
    self.cached = nil;
  }
}

@end
