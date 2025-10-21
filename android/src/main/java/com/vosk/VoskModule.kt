package com.vosk

import android.util.Log
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.IOException
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import com.vosk.NativeVoskSpec

@ReactModule(name = VoskModule.NAME)
class VoskModule(reactContext: ReactApplicationContext) :
        NativeVoskSpec(reactContext), RecognitionListener {

  private var model: Model? = null
  private var speechService: SpeechService? = null
  private var context: ReactApplicationContext? = reactContext
  private var recognizer: Recognizer? = null
  private var sampleRate = 16000.0f
  private var isStopping = false
  private var currentModelPath: String? = null

  override fun getName(): String {
    return NAME
  }

  override fun onResult(hypothesis: String) {
    // Get text data from string object
    val text = parseHypothesis(hypothesis)

    // Send event if data found
    if (!text.isNullOrEmpty()) {
      emitOnResult(text)
    }
  }

  override fun onFinalResult(hypothesis: String) {
    // Get text data from string object
    val text = parseHypothesis(hypothesis)

    // Send event if data found
    if (!text.isNullOrEmpty()) {
      emitOnFinalResult(text)
    }
  }

  override fun onPartialResult(hypothesis: String) {
    // Get text data from string object
    val text = parseHypothesis(hypothesis, "partial")

    // Send event if data found
    if (!text.isNullOrEmpty()) {
      emitOnPartialResult(text)
    }
  }

  override fun onError(e: Exception) {
    emitOnError(e.toString())
  }

  override fun onTimeout() {
    cleanRecognizer()
    emitOnTimeout()
  }

  /**
   * Converts hypothesis json text to the recognized text
   * @return the recognized text or null if something went wrong
   */
  private fun parseHypothesis(hypothesis: String, key: String = "text"): String? {
    if (hypothesis.isEmpty()) {
      return null
    }
    val needle = "\"$key\""
    val keyIndex = hypothesis.indexOf(needle)
    if (keyIndex == -1) {
      return null
    }
    var index = keyIndex + needle.length
    val length = hypothesis.length
    while (index < length && hypothesis[index].isWhitespace()) {
      index++
    }
    if (index >= length || hypothesis[index] != ':') {
      return null
    }
    index++
    while (index < length && hypothesis[index].isWhitespace()) {
      index++
    }
    if (index >= length) {
      return null
    }
    if (hypothesis[index] != '"') {
      val end = hypothesis.indexOfAny(charArrayOf(',', '}'), index).let { if (it == -1) length else it }
      return hypothesis.substring(index, end).trim().takeIf { it.isNotEmpty() }
    }
    index++
    val builder = StringBuilder()
    var i = index
    while (i < length) {
      when (val ch = hypothesis[i]) {
        '"' -> return builder.toString().takeIf { it.isNotEmpty() }
        '\\' -> {
          if (i + 1 >= length) {
            break
          }
          val next = hypothesis[i + 1]
          when (next) {
            '\\', '"', '/' -> builder.append(next)
            'b' -> builder.append('\b')
            'f' -> builder.append('\u000C')
            'n' -> builder.append('\n')
            'r' -> builder.append('\r')
            't' -> builder.append('\t')
            'u' -> {
              if (i + 5 < length) {
                val hex = hypothesis.substring(i + 2, i + 6)
                hex.toIntOrNull(16)?.let { builder.append(it.toChar()) }
                i += 4
              }
            }
            else -> builder.append(next)
          }
          i++
        }
        else -> builder.append(ch)
      }
      i++
    }
    return null
  }

  /** Sends event to react native with associated data */
  private fun sendEvent(eventName: String, data: String? = null) {
    // Send event
    context?.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            ?.emit(eventName, data)
  }

  /**
   * Translates array of string(s) to required kaldi string format
   * @return the array of string(s) as a single string
   */
  private fun makeGrammar(grammarArray: ReadableArray): String {
    return grammarArray
            .toArrayList()
            .joinToString(
                    prefix = "[",
                    separator = ", ",
                    transform = { "\"" + it + "\"" },
                    postfix = "]"
            )
  }

  override fun loadModel(path: String, promise: Promise) {
    val ctx = context
    if (ctx == null) {
      promise.reject(IOException("React context is no longer available"))
      return
    }
    val normalizedPath = if (path.startsWith("file://")) path.removePrefix("file://") else path
    val previousPath = currentModelPath
    if (normalizedPath == previousPath && model != null) {
      promise.resolve(null)
      return
    }

    val reusedModel = VoskModelCache.prepareForReuse(normalizedPath)
    if (reusedModel != null) {
      synchronized(this) {
        model = reusedModel
        currentModelPath = normalizedPath
      }
      promise.resolve(null)
      return
    }

    VoskModelCache.loadFresh(
        ctx,
        normalizedPath,
        onSuccess = { loadedModel ->
          synchronized(this) {
            model = loadedModel
            currentModelPath = normalizedPath
          }
          promise.resolve(null)
        },
        onError = { error ->
          var wasRestored = false
          if (previousPath != null) {
            VoskModelCache.prepareForReuse(previousPath)?.let { restored ->
              synchronized(this) {
                model = restored
                currentModelPath = previousPath
              }
              wasRestored = true
            }
          }
          if (!wasRestored) {
            synchronized(this) {
              model = null
              currentModelPath = null
            }
          }
          promise.reject(error)
        })
  }

  override fun start(options: ReadableMap?, promise: Promise) {
    if (model == null) {
      promise.reject(IOException("Model is not loaded yet"))
      return
    }
    if (speechService != null) {
      promise.reject(IOException("Recognizer is already in use"))
      return
    }
    try {
      recognizer =
              if (options != null && options.hasKey("grammar") && !options.isNull("grammar")) {
                Recognizer(model, sampleRate, makeGrammar(options.getArray("grammar")!!))
              } else {
                Recognizer(model, sampleRate)
              }
      speechService = SpeechService(recognizer, sampleRate)
      val started =
              if (options != null && options.hasKey("timeout") && !options.isNull("timeout")) {
                speechService?.startListening(this, options.getInt("timeout")) ?: false
              } else {
                speechService!!.startListening(this)
              }
      if (started) {
        promise.resolve("Recognizer successfully started")
      } else {
        cleanRecognizer()
        promise.reject(IOException("Recognizer couldn't be started"))
      }
    } catch (e: IOException) {
      cleanRecognizer()
      promise.reject(e)
    }
  }

  private fun cleanRecognizer() {
    synchronized(this) {
      if (isStopping) {
        return
      }
      isStopping = true
      try {
        speechService?.let {
          it.stop()
          it.shutdown()
          speechService = null
        }
        recognizer?.let {
          it.close()
          recognizer = null
        }
      } catch (e: Exception) {
        Log.w(NAME, "Error during cleanup in cleanRecognizer", e)
      } finally {
        isStopping = false
      }
    }
  }

  private fun releaseCurrentModel(clearCache: Boolean) {
    synchronized(this) {
      if (clearCache) {
        VoskModelCache.clear()
      } else {
        try {
          VoskModelCache.releaseActive(keepCached = true)
        } catch (e: Exception) {
          Log.w(NAME, "Error releasing model", e)
        }
      }
      model = null
      currentModelPath = null
    }
  }

  private fun cleanModel() {
    releaseCurrentModel(false)
  }

  override fun stop() {
    cleanRecognizer()
  }

  override fun unload() {
    cleanRecognizer()
    cleanModel()
  }

  override fun addListener(type: String?) {
    // Keep: Required for RN built in Event Emitter Calls.
  }

  override fun removeListeners(count: Double): Unit {
    // Keep: Required for RN built in Event Emitter Calls.
  }

  override fun invalidate() {
    cleanRecognizer()
    releaseCurrentModel(true)
    super.invalidate()
  }

  companion object {
    const val NAME = "Vosk"
  }
}
