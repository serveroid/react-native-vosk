package com.vosk

import android.content.Context
import java.io.IOException
import org.vosk.Model
import org.vosk.android.StorageService

internal object VoskModelCache {
  private data class CachedModel(val path: String, val model: Model)

  private val lock = Any()
  private var active: CachedModel? = null
  private var cached: CachedModel? = null

  private fun normalize(path: String): String {
    return if (path.startsWith("file://")) path.removePrefix("file://") else path
  }

  private fun addToCache(entry: CachedModel?) {
    if (entry == null) {
      return
    }
    if (cached?.model === entry.model) {
      cached = entry
      return
    }
    cached?.model?.close()
    cached = entry
  }

  fun prepareForReuse(newPath: String): Model? {
    val normalizedPath = normalize(newPath)
    synchronized(lock) {
      active?.takeIf { it.path == normalizedPath }?.let { return it.model }

      val previousActive = active
      val cachedMatch = cached?.takeIf { it.path == normalizedPath }
      if (cachedMatch != null) {
        cached = null
        addToCache(previousActive)
        active = cachedMatch
        return cachedMatch.model
      }

      addToCache(previousActive)
      active = null
      return null
    }
  }

  fun registerActive(path: String, model: Model) {
    val normalizedPath = normalize(path)
    synchronized(lock) {
      active?.takeIf { it.model !== model }?.model?.close()
      active = CachedModel(normalizedPath, model)
    }
  }

  fun loadFresh(
      context: Context?,
      path: String,
      onSuccess: (Model) -> Unit,
      onError: (Exception) -> Unit
  ) {
    val normalizedPath = normalize(path)
    try {
      val model = Model(normalizedPath)
      registerActive(normalizedPath, model)
      onSuccess(model)
      return
    } catch (directException: IOException) {
      if (context == null) {
        onError(directException)
        return
      }

      StorageService.unpack(
          context,
          normalizedPath,
          "models",
          { loadedModel ->
            if (loadedModel == null) {
              onError(IOException("Model directory does not exist at path: $normalizedPath"))
              return@unpack
            }
            registerActive(normalizedPath, loadedModel)
            onSuccess(loadedModel)
          }) { error ->
            onError(error)
          }
    }
  }

  fun releaseActive(keepCached: Boolean) {
    synchronized(lock) {
      val current = active ?: return
      if (keepCached) {
        addToCache(current)
      } else {
        current.model.close()
      }
      active = null
    }
  }

  fun clear() {
    synchronized(lock) {
      active?.model?.close()
      cached?.model?.close()
      active = null
      cached = null
    }
  }
}
