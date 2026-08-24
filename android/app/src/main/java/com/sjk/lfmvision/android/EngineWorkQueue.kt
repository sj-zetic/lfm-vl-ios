package com.sjk.lfmvision.android

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex

internal class EngineWorkQueue(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val mutex = Mutex()
    private var activeJob: Job? = null

    fun launch(block: suspend () -> Unit) {
        activeJob = scope.launch {
            mutex.lock()
            try {
                block()
            } finally {
                mutex.unlock()
            }
        }
    }

    fun cancelActive() {
        activeJob?.cancel()
    }

    fun close(close: suspend () -> Unit) {
        val runningJob = activeJob
        runningJob?.cancel()
        scope.launch {
            runningJob?.join()
            mutex.lock()
            try {
                close()
            } finally {
                mutex.unlock()
                scope.cancel()
            }
        }
    }
}
