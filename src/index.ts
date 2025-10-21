import { PermissionsAndroid, Platform } from 'react-native';
import NativeVosk, { type VoskOptions } from './NativeVosk';

export type { VoskOptions } from './NativeVosk';

/**
 * Loads the model from specified path. The native layer keeps the most recent
 * model in-memory so switching back to it is instantaneous.
 *
 * @param path - Path of the model.
 * @returns A promise that resolves when the model is loaded
 * @example
 *   loadModel('model-fr-fr').then(() => {
 *      setLoaded(true);
 *   });
 */
function loadModelImpl(path: string) {
  return NativeVosk.loadModel(path);
}

export function loadModel(path: string) {
  return loadModelImpl(path);
}

/**
 * Unloads the model, also stops the recognizer.
 *
 * @example
 *   unload().then(() => {
 *      setLoaded(false);
 *   });
 * @returns A promise that resolves when the model is unloaded
 */
function unloadImpl() {
  return NativeVosk.unload();
}

export function unload() {
  return unloadImpl();
}

/**
 * Requests record permission on Android.
 *
 * @returns true if permission is granted, false otherwise
 * @private
 */
async function requestRecordPermission() {
  if (Platform.OS === 'ios') return true;
  const granted = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.RECORD_AUDIO!
  );
  return granted === PermissionsAndroid.RESULTS.GRANTED;
}

/**
 * Asks for recording permissions then starts the recognizer.
 *
 * @param options - Optional settings for the recognizer.
 * @returns A promise that resolves when the recognizer has started
 * @example
 *   start().then(() => console.log("Recognizer started"));
 *
 *   start({
 *      grammar: ['cool', 'application', '[unk]'],
 *      timeout: 5000,
 *   }).catch(e => console.log(e));
 */
function startImpl(options?: VoskOptions) {
  return requestRecordPermission().then((granted) => {
    if (granted) return NativeVosk.start(options);
    return Promise.reject('Record permission not granted');
  });
}

export function start(options?: VoskOptions) {
  return startImpl(options);
}

/**
 * Stops the recognizer. Listener should receive final result if there is any.
 *
 * @example
 *   stop();
 * @returns void
 */
function stopImpl() {
  return NativeVosk.stop();
}

export function stop() {
  return stopImpl();
}

/**
 * Event listener for error event
 *
 * @param cb - Callback to be called on error event
 * @returns A subscription to the event
 */
function onErrorImpl(cb: (e: any) => void) {
  return NativeVosk.onError(cb);
}

export function onError(cb: (e: any) => void) {
  return onErrorImpl(cb);
}

/** Event listener for timeout event
 *
 * @param cb - Callback to be called on timeout event
 * @returns A subscription to the event
 */
function onTimeoutImpl(cb: () => void) {
  return NativeVosk.onTimeout(cb);
}

export function onTimeout(cb: () => void) {
  return onTimeoutImpl(cb);
}

/** Event listener for partial result event
 *
 * @param cb - Callback to be called on partial result event
 * @returns A subscription to the event
 */
function onPartialResultImpl(cb: (e: string) => void) {
  return NativeVosk.onPartialResult(cb);
}

export function onPartialResult(cb: (e: string) => void) {
  return onPartialResultImpl(cb);
}

/** Event listener for final result event
 *
 * @param cb - Callback to be called on final result event
 * @returns A subscription to the event
 */
function onFinalResultImpl(cb: (e: string) => void) {
  return NativeVosk.onFinalResult(cb);
}

export function onFinalResult(cb: (e: string) => void) {
  return onFinalResultImpl(cb);
}

/** Event listener for result event
 *
 * @param cb - Callback to be called on result event
 * @returns A subscription to the event
 */
function onResultImpl(cb: (e: string) => void) {
  return NativeVosk.onResult(cb);
}

export function onResult(cb: (e: string) => void) {
  return onResultImpl(cb);
}

class Vosk {
  loadModel(path: string) {
    return loadModelImpl(path);
  }

  unload() {
    return unloadImpl();
  }

  start(options?: VoskOptions) {
    return startImpl(options);
  }

  stop() {
    return stopImpl();
  }

  onError(cb: (e: any) => void) {
    return onErrorImpl(cb);
  }

  onTimeout(cb: () => void) {
    return onTimeoutImpl(cb);
  }

  onPartialResult(cb: (e: string) => void) {
    return onPartialResultImpl(cb);
  }

  onFinalResult(cb: (e: string) => void) {
    return onFinalResultImpl(cb);
  }

  onResult(cb: (e: string) => void) {
    return onResultImpl(cb);
  }

  static loadModel(path: string) {
    return loadModelImpl(path);
  }

  static unload() {
    return unloadImpl();
  }

  static start(options?: VoskOptions) {
    return startImpl(options);
  }

  static stop() {
    return stopImpl();
  }

  static onError(cb: (e: any) => void) {
    return onErrorImpl(cb);
  }

  static onTimeout(cb: () => void) {
    return onTimeoutImpl(cb);
  }

  static onPartialResult(cb: (e: string) => void) {
    return onPartialResultImpl(cb);
  }

  static onFinalResult(cb: (e: string) => void) {
    return onFinalResultImpl(cb);
  }

  static onResult(cb: (e: string) => void) {
    return onResultImpl(cb);
  }
}

export default Vosk;
