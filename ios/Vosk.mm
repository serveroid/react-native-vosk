#import "Vosk.h"

#import "RNVoskModel.h"
#import "RNVoskModelCache.h"
#import "Vosk-API.h"

#import <AVFoundation/AVFoundation.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTUtils.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

using namespace facebook::react;

static void *kProcessingQueueKey = &kProcessingQueueKey;
static NSString *const kEventError = @"onError";
static NSString *const kEventResult = @"onResult";
static NSString *const kEventFinal = @"onFinalResult";
static NSString *const kEventPartial = @"onPartialResult";
static NSString *const kEventTimeout = @"onTimeout";

static NSString *NormalizeModelPath(NSString *path) {
  if ([path hasPrefix:@"file://"]) {
    return [path substringFromIndex:7];
  }
  return path;
}

static NSString *GrammarSignature(NSArray<NSString *> *grammar) {
  if (grammar.count == 0) {
    return @"<default>";
  }
  NSMutableString *signature = [NSMutableString stringWithCapacity:grammar.count * 8];
  for (NSString *token in grammar) {
    [signature appendString:token];
    [signature appendString:@"\u0001"]; // unlikely separator
  }
  return signature;
}

static std::string GrammarJSON(NSArray<NSString *> *grammar) {
  if (grammar.count == 0) {
    return std::string();
  }
  std::ostringstream stream;
  stream << "[";
  for (NSUInteger index = 0; index < grammar.count; ++index) {
    NSString *token = grammar[index];
    std::string utf8([token UTF8String]);
    stream << '\"';
    for (char c : utf8) {
      switch (c) {
      case '\\':
        stream << "\\\\";
        break;
      case '\"':
        stream << "\\\"";
        break;
      default:
        stream << c;
        break;
      }
    }
    stream << '\"';
    if (index + 1 < grammar.count) {
      stream << ",";
    }
  }
  stream << "]";
  return stream.str();
}

static NSArray<NSString *> *ConvertGrammar(
    const std::optional<LazyVector<NSString *>> &grammarOpt) {
  if (!grammarOpt.has_value()) {
    return @[];
  }
  const LazyVector<NSString *> &grammarVec = grammarOpt.value();
  if (grammarVec.size() == 0) {
    return @[];
  }
  NSMutableArray<NSString *> *collector =
      [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(grammarVec.size())];
  for (size_t i = 0; i < grammarVec.size(); ++i) {
    NSString *entry = grammarVec.at(static_cast<int>(i));
    if (entry) {
      [collector addObject:entry];
    }
  }
  return collector;
}

static NSString *ExtractJsonString(const char *json, const char *key) {
  if (json == nullptr || key == nullptr) {
    return nil;
  }
  const char *cursor = strstr(json, key);
  if (!cursor) {
    return nil;
  }
  cursor += strlen(key);
  while (*cursor && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' ||
                     *cursor == '\n')) {
    ++cursor;
  }
  if (*cursor != ':') {
    return nil;
  }
  ++cursor;
  while (*cursor && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' ||
                     *cursor == '\n')) {
    ++cursor;
  }
  if (*cursor == '\"') {
    ++cursor;
    std::string output;
    output.reserve(32);
    while (*cursor && *cursor != '\"') {
      if (*cursor == '\\') {
        ++cursor;
        if (!*cursor) {
          break;
        }
        switch (*cursor) {
        case '\\':
        case '\"':
        case '/':
          output.push_back(*cursor);
          break;
        case 'b':
          output.push_back('\b');
          break;
        case 'f':
          output.push_back('\f');
          break;
        case 'n':
          output.push_back('\n');
          break;
        case 'r':
          output.push_back('\r');
          break;
        case 't':
          output.push_back('\t');
          break;
        case 'u': {
          char buffer[5] = {0};
          for (int i = 0; i < 4 && cursor[i + 1]; ++i) {
            buffer[i] = cursor[i + 1];
          }
          unsigned long value = strtoul(buffer, nullptr, 16);
          if (value > 0 && value <= 0x10FFFF) {
            if (value <= 0x7F) {
              output.push_back(static_cast<char>(value));
            } else {
              unichar utf16 = static_cast<unichar>(value);
              NSString *segment =
                  [NSString stringWithCharacters:&utf16 length:1];
              NSData *data =
                  [segment dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
              if (data) {
                output.append(static_cast<const char *>(data.bytes), data.length);
              }
            }
          }
          cursor += 4;
          break;
        }
        default:
          output.push_back(*cursor);
          break;
        }
      } else {
        output.push_back(*cursor);
      }
      ++cursor;
    }
    return [[NSString alloc] initWithBytes:output.data()
                                     length:output.size()
                                   encoding:NSUTF8StringEncoding];
  }
  const char *end = cursor;
  while (*end && *end != ',' && *end != '}') {
    ++end;
  }
  if (end <= cursor) {
    return nil;
  }
  std::string output(cursor, end - cursor);
  size_t start = output.find_first_not_of(" \t\r\n");
  size_t finish = output.find_last_not_of(" \t\r\n");
  if (start == std::string::npos || finish == std::string::npos) {
    return nil;
  }
  std::string trimmed = output.substr(start, finish - start + 1);
  return [[NSString alloc] initWithBytes:trimmed.data()
                                   length:trimmed.size()
                                 encoding:NSUTF8StringEncoding];
}

@interface Vosk () {
  dispatch_queue_t _processingQueue;
  std::vector<int16_t> _pcmScratch;
  AVAudioEngine *_engine;
  AVAudioInputNode *_inputNode;
  AVAudioFormat *_tapFormat;
  dispatch_source_t _timeoutSource;
  RNVoskModel *_currentModel;
  NSString *_currentModelPath;
  VoskRecognizer *_recognizer;
  NSString *_recognizerSignature;
  NSString *_lastPartial;
  BOOL _isRunning;
  BOOL _isStarting;
  BOOL _tapInstalled;
  BOOL _sessionConfigured;
  double _currentSampleRate;
}
@end

@implementation Vosk

RCT_EXPORT_MODULE();

- (instancetype)init {
  if ((self = [super init])) {
    _processingQueue =
        dispatch_queue_create("com.vosk.recognition", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_processingQueue, kProcessingQueueKey,
                                kProcessingQueueKey, NULL);
    _engine = nil;
    _inputNode = nil;
    _tapFormat = nil;
    _timeoutSource = nil;
    _currentModel = nil;
    _currentModelPath = nil;
    _recognizer = NULL;
    _recognizerSignature = nil;
    _lastPartial = nil;
    _isRunning = NO;
    _isStarting = NO;
    _tapInstalled = NO;
    _sessionConfigured = NO;
    _currentSampleRate = 16000.0;
    _pcmScratch.reserve(4096);
  }
  return self;
}

- (void)dealloc {
  [self stopInternal:NO];
  dispatch_sync(_processingQueue, ^{
    if (self->_recognizer) {
      vosk_recognizer_free(self->_recognizer);
      self->_recognizer = NULL;
    }
  });
  [[RNVoskModelCache sharedCache] clear];
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ kEventError, kEventResult, kEventFinal, kEventPartial, kEventTimeout ];
}

- (void)emitEvent:(NSString *)type body:(id)body {
  if (!self.bridge) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [(RCTEventEmitter *)self sendEventWithName:type body:body];
  });
}

- (void)emitErrorMessage:(NSString *)message {
  [self emitEvent:kEventError body:message];
}

- (BOOL)ensureEngineWithError:(NSError **)error {
  if (_engine && _inputNode) {
    return YES;
  }
  _engine = [AVAudioEngine new];
  _inputNode = _engine.inputNode;
  if (!_inputNode) {
    if (error) {
      *error = [NSError errorWithDomain:@"Vosk"
                                   code:-10
                               userInfo:@{NSLocalizedDescriptionKey :
                                              @"Input node is unavailable"}];
    }
    return NO;
  }
  _tapInstalled = NO;
  _tapFormat = nil;
  return YES;
}

- (double)activeSampleRate {
  if (_tapFormat && _tapFormat.sampleRate > 0) {
    return _tapFormat.sampleRate;
  }
  AVAudioFormat *format = [_inputNode inputFormatForBus:0];
  if (format && format.sampleRate > 0) {
    return format.sampleRate;
  }
  return 16000.0;
}

- (BOOL)configureSession:(NSError **)error {
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *sessionError = nil;
  if (!_sessionConfigured) {
    if (@available(iOS 10.0, *)) {
      if (![session setCategory:AVAudioSessionCategoryRecord
                       withOptions:AVAudioSessionCategoryOptionAllowBluetooth |
                                   AVAudioSessionCategoryOptionMixWithOthers
                             error:&sessionError]) {
        if (error) {
          *error = sessionError;
        }
        return NO;
      }
      if (![session setMode:AVAudioSessionModeMeasurement error:&sessionError]) {
        if (error) {
          *error = sessionError;
        }
        return NO;
      }
    } else {
      if (![session setCategory:AVAudioSessionCategoryRecord error:&sessionError]) {
        if (error) {
          *error = sessionError;
        }
        return NO;
      }
    }
    [session setPreferredIOBufferDuration:0.01 error:nil];
    [session setPreferredSampleRate:16000 error:nil];
    [session setPreferredInputNumberOfChannels:1 error:nil];
    _sessionConfigured = YES;
  }
  if (![session setActive:YES error:&sessionError]) {
    if (error) {
      *error = sessionError;
    }
    return NO;
  }
  return YES;
}

- (void)deactivateSession {
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *deactivateError = nil;
  [session setActive:NO
         withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
               error:&deactivateError];
}

- (BOOL)prepareTapIfNeeded:(NSError **)error {
  if (_tapInstalled) {
    return YES;
  }
  double sampleRate = [self activeSampleRate];
  _currentSampleRate = sampleRate;
  _tapFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                 sampleRate:sampleRate
                                                   channels:1
                                                interleaved:NO];
  if (!_tapFormat) {
    if (error) {
      *error = [NSError errorWithDomain:@"Vosk"
                                   code:-11
                               userInfo:@{NSLocalizedDescriptionKey :
                                              @"Unable to configure tap format"}];
    }
    return NO;
  }
  __weak __typeof(self) weakSelf = self;
  [_inputNode removeTapOnBus:0];
  @try {
    [_inputNode installTapOnBus:0
                     bufferSize:1024
                         format:_tapFormat
                          block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                            __strong __typeof(self) strongSelf = weakSelf;
                            if (!strongSelf) {
                              return;
                            }
                            [strongSelf handleAudioBuffer:buffer];
                          }];
  } @catch (NSException *exception) {
    if (error) {
      *error = [NSError errorWithDomain:@"Vosk"
                                   code:-12
                               userInfo:@{NSLocalizedDescriptionKey :
                                              exception.reason ?: @"Tap install failed"}];
    }
    return NO;
  }
  _tapInstalled = YES;
  return YES;
}

- (void)handleAudioBuffer:(AVAudioPCMBuffer *)buffer {
  if (!_isRunning) {
    return;
  }
  AVAudioFrameCount frames = buffer.frameLength;
  if (frames == 0) {
    return;
  }
  __weak __typeof(self) weakSelf = self;
  dispatch_async(_processingQueue, ^{
    __strong __typeof(self) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_isRunning || !strongSelf->_recognizer) {
      return;
    }
    size_t frameCount = static_cast<size_t>(frames);
    strongSelf->_pcmScratch.resize(frameCount);
    if (buffer.int16ChannelData && buffer.int16ChannelData[0]) {
      const int16_t *source = buffer.int16ChannelData[0];
      std::copy(source, source + frameCount, strongSelf->_pcmScratch.begin());
    } else if (buffer.floatChannelData && buffer.floatChannelData[0]) {
      const float *source = buffer.floatChannelData[0];
      for (size_t i = 0; i < frameCount; ++i) {
        float sample = source[i];
        if (sample > 1.0f) {
          sample = 1.0f;
        } else if (sample < -1.0f) {
          sample = -1.0f;
        }
        strongSelf->_pcmScratch[i] =
            static_cast<int16_t>(lrintf(sample * 32767.0f));
      }
    } else {
      return;
    }
    const int32_t byteLength = static_cast<int32_t>(frameCount * sizeof(int16_t));
    int accepted =
        vosk_recognizer_accept_waveform(strongSelf->_recognizer,
                                        reinterpret_cast<const char *>(
                                            strongSelf->_pcmScratch.data()),
                                        byteLength);
    const char *json = nullptr;
    if (accepted) {
      json = vosk_recognizer_result(strongSelf->_recognizer);
    } else {
      json = vosk_recognizer_partial_result(strongSelf->_recognizer);
    }
    if (!json) {
      return;
    }
    if (accepted) {
      NSString *text =
          ExtractJsonString(json, "\"text\"");
      if (text.length > 0) {
        strongSelf->_lastPartial = nil;
        [strongSelf emitEvent:kEventResult body:text];
        [strongSelf emitEvent:kEventFinal body:text];
      }
    } else {
      NSString *partial =
          ExtractJsonString(json, "\"partial\"");
      if (partial.length > 0 &&
          (!strongSelf->_lastPartial ||
           ![strongSelf->_lastPartial isEqualToString:partial])) {
        strongSelf->_lastPartial = partial;
        [strongSelf emitEvent:kEventPartial body:partial];
      }
    }
  });
}

- (BOOL)prepareRecognizerWithGrammar:(NSArray<NSString *> *)grammar
                          sampleRate:(double)sampleRate
                                error:(NSError **)error {
  __block BOOL success = YES;
  __block NSError *localError = nil;
  NSString *signature = GrammarSignature(grammar ?: @[]);
  dispatch_sync(_processingQueue, ^{
    if (!self->_currentModel) {
      success = NO;
      localError =
          [NSError errorWithDomain:@"Vosk"
                              code:-13
                          userInfo:@{NSLocalizedDescriptionKey :
                                         @"Model is not loaded"}];
      return;
    }
    if (self->_recognizer &&
        (!self->_recognizerSignature ||
         ![self->_recognizerSignature isEqualToString:signature] ||
         fabs(self->_currentSampleRate - sampleRate) > 0.01)) {
      vosk_recognizer_free(self->_recognizer);
      self->_recognizer = NULL;
      self->_recognizerSignature = nil;
    }
    if (!self->_recognizer) {
      std::string grammarJson = GrammarJSON(grammar ?: @[]);
      if (!grammarJson.empty()) {
        self->_recognizer = vosk_recognizer_new_grm(
            self->_currentModel.model, (float)sampleRate, grammarJson.c_str());
      } else {
        self->_recognizer =
            vosk_recognizer_new(self->_currentModel.model, (float)sampleRate);
      }
      if (!self->_recognizer) {
        success = NO;
        localError = [NSError errorWithDomain:@"Vosk"
                                         code:-14
                                     userInfo:@{
                                       NSLocalizedDescriptionKey :
                                           @"Unable to create recognizer"
                                     }];
        return;
      }
      vosk_recognizer_set_max_alternatives(self->_recognizer, 0);
      vosk_recognizer_set_words(self->_recognizer, 1);
      if (self->_currentModel.spkModel) {
        vosk_recognizer_set_spk_model(self->_recognizer,
                                      self->_currentModel.spkModel);
      }
      self->_recognizerSignature = signature;
    } else {
      vosk_recognizer_reset(self->_recognizer);
    }
    self->_currentSampleRate = sampleRate;
    self->_lastPartial = nil;
  });
  if (!success && error) {
    *error = localError;
  }
  return success;
}

- (void)clearRecognizer {
  dispatch_sync(_processingQueue, ^{
    if (self->_recognizer) {
      vosk_recognizer_free(self->_recognizer);
      self->_recognizer = NULL;
      self->_recognizerSignature = nil;
    }
    self->_lastPartial = nil;
  });
}

- (void)loadModel:(NSString *)path
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject {
  NSString *normalized = NormalizeModelPath(path);
  if (_currentModel && [_currentModelPath isEqualToString:normalized]) {
    resolve(nil);
    return;
  }
  NSString *previousPath = _currentModelPath;
  RNVoskModel *previousModel = _currentModel;
  NSError *error = nil;
  RNVoskModel *model =
      [[RNVoskModelCache sharedCache] acquireModelAtPath:normalized error:&error];
  if (!model) {
    if (previousModel && previousPath) {
      _currentModel = previousModel;
      _currentModelPath = previousPath;
    }
    reject(@"loadModel",
           error.localizedDescription ?: @"Failed to load Vosk model", error);
    return;
  }
  _currentModel = model;
  _currentModelPath = normalized;
  NSError *engineError = nil;
  if (![self ensureEngineWithError:&engineError]) {
    [self emitErrorMessage:engineError.localizedDescription];
  }
  [self clearRecognizer];
  resolve(nil);
}

- (void)start:(JS::NativeVosk::VoskOptions const *_Nullable)options
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject {
  if (_currentModel == nil) {
    reject(@"start", @"Model is not loaded", nil);
    return;
  }
  if (_isRunning || _isStarting) {
    reject(@"start", @"Recognizer already running", nil);
    return;
  }
  _isStarting = YES;

  AVAudioSession *session = [AVAudioSession sharedInstance];
  AVAudioSessionRecordPermission permission =
      [session respondsToSelector:@selector(recordPermission)]
          ? session.recordPermission
          : AVAudioSessionRecordPermissionUndetermined;

  auto begin = ^{
    NSError *engineError = nil;
    if (![self ensureEngineWithError:&engineError]) {
      self->_isStarting = NO;
      reject(@"start", engineError.localizedDescription, engineError);
      return;
    }
    NSError *sessionError = nil;
    if (![self configureSession:&sessionError]) {
      self->_isStarting = NO;
      [self emitErrorMessage:sessionError.localizedDescription];
      reject(@"start", sessionError.localizedDescription, sessionError);
      return;
    }
    NSError *tapError = nil;
    if (![self prepareTapIfNeeded:&tapError]) {
      self->_isStarting = NO;
      [self emitErrorMessage:tapError.localizedDescription];
      reject(@"start", tapError.localizedDescription, tapError);
      return;
    }

    NSArray<NSString *> *grammar = @[];
    double timeoutMs = -1;
    if (options) {
      if (options->grammar()) {
        grammar = ConvertGrammar(options->grammar());
      }
      if (options->timeout()) {
        timeoutMs = *(options->timeout());
      }
    }

    NSError *recognizerError = nil;
    double sampleRate = [self activeSampleRate];
    if (![self prepareRecognizerWithGrammar:grammar
                                  sampleRate:sampleRate
                                        error:&recognizerError]) {
      self->_isStarting = NO;
      [self emitErrorMessage:recognizerError.localizedDescription];
      reject(@"start", recognizerError.localizedDescription, recognizerError);
      return;
    }

    NSError *startError = nil;
    [_engine prepare];
    if (![_engine startAndReturnError:&startError]) {
      self->_isStarting = NO;
      [self emitErrorMessage:startError.localizedDescription];
      reject(@"start", startError.localizedDescription, startError);
      return;
    }

    self->_isRunning = YES;
    self->_isStarting = NO;

    if (timeoutMs >= 0) {
      if (self->_timeoutSource) {
        dispatch_source_cancel(self->_timeoutSource);
        self->_timeoutSource = nil;
      }
      dispatch_source_t timer =
          dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                 self->_processingQueue);
      if (timer) {
        uint64_t delay = (uint64_t)(timeoutMs * NSEC_PER_MSEC);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delay),
                                  DISPATCH_TIME_FOREVER, 5 * NSEC_PER_MSEC);
        __weak __typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
          __strong __typeof(self) strongSelf = weakSelf;
          if (!strongSelf || !strongSelf->_isRunning) {
            return;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf stopInternal:NO];
            [strongSelf emitEvent:kEventTimeout body:nil];
          });
        });
        dispatch_resume(timer);
        self->_timeoutSource = timer;
      }
    }

    resolve(nil);
  };

  switch (permission) {
  case AVAudioSessionRecordPermissionGranted:
    begin();
    break;
  case AVAudioSessionRecordPermissionDenied:
    _isStarting = NO;
    reject(@"start", @"Microphone permission denied", nil);
    break;
  case AVAudioSessionRecordPermissionUndetermined:
  default: {
    [session requestRecordPermission:^(BOOL granted) {
      if (!granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          self->_isStarting = NO;
          reject(@"start", @"Microphone permission denied", nil);
        });
        return;
      }
      dispatch_async(dispatch_get_main_queue(), begin);
    }];
    break;
  }
  }
}

- (void)stopInternal:(BOOL)emitFinal {
  if (!_engine) {
    _isRunning = NO;
    _isStarting = NO;
    return;
  }
  if (_timeoutSource) {
    dispatch_source_cancel(_timeoutSource);
    _timeoutSource = nil;
  }
  if (_tapInstalled) {
    @try {
      [_inputNode removeTapOnBus:0];
    } @catch (...) {
    }
    _tapInstalled = NO;
  }
  if (_engine.isRunning) {
    [_engine stop];
  }
  _isRunning = NO;
  _isStarting = NO;

  NSString *__block finalPartial = nil;
  void (^drainRecognizer)(void) = ^{
    if (emitFinal && self->_recognizer) {
      const char *json = vosk_recognizer_final_result(self->_recognizer);
      if (json) {
        NSString *text = ExtractJsonString(json, "\"text\"");
        if (text.length == 0 && self->_lastPartial.length > 0) {
          text = self->_lastPartial;
        }
        finalPartial = text;
      }
      vosk_recognizer_reset(self->_recognizer);
    } else if (emitFinal && self->_lastPartial.length > 0) {
      finalPartial = self->_lastPartial;
      self->_lastPartial = nil;
    } else {
      self->_lastPartial = nil;
    }
  };
  if (dispatch_get_specific(kProcessingQueueKey)) {
    drainRecognizer();
  } else {
    dispatch_sync(_processingQueue, drainRecognizer);
  }

  if (emitFinal && finalPartial.length > 0) {
    [self emitEvent:kEventFinal body:finalPartial];
    [self emitEvent:kEventResult body:finalPartial];
  }

  [self deactivateSession];
}

- (void)stop {
  [self stopInternal:YES];
}

- (void)unload {
  [self stopInternal:NO];
  [self clearRecognizer];
  [[RNVoskModelCache sharedCache] releaseActiveKeepingCache:YES];
  _currentModel = nil;
  _currentModelPath = nil;
}

- (void)addListener:(NSString *)eventType {
  // Required for RCTEventEmitter compatibility.
}

- (void)removeListeners:(double)count {
  // Required for RCTEventEmitter compatibility.
}

- (std::shared_ptr<TurboModule>)getTurboModule:
    (const ObjCTurboModule::InitParams &)params {
  return std::make_shared<NativeVoskSpecJSI>(params);
}

@end
