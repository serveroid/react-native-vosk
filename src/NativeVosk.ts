import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

type EventSubscription = { remove(): void };
type EventEmitter<T> = (
  handler: (value: T) => void | Promise<void>
) => EventSubscription;

export type VoskOptions = {
  /**
   * Set of phrases the recognizer will seek on which is the closest one from
   * the record, add `"[unk]"` to the set to recognize phrases striclty.
   */
  grammar?: string[];
  /**
   * Timeout in milliseconds to listen.
   */
  timeout?: number;
};

export interface Spec extends TurboModule {
  loadModel: (path: string) => Promise<void>;
  unload: () => void;

  start: (options?: VoskOptions) => Promise<void>;
  stop: () => void;

  addListener: (eventType: string) => void;
  removeListeners: (count: number) => void;

  readonly onResult: EventEmitter<string>;
  readonly onPartialResult: EventEmitter<string>;
  readonly onFinalResult: EventEmitter<string>;
  readonly onError: EventEmitter<string>;
  readonly onTimeout: EventEmitter<void>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Vosk');
