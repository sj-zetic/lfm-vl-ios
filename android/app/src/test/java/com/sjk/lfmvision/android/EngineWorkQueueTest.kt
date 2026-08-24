package com.sjk.lfmvision.android

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class EngineWorkQueueTest {
    @Test fun closeCancelsActiveWorkBeforeClosingEngine() = runBlocking {
        val events = mutableListOf<String>()
        val started = CompletableDeferred<Unit>()
        val closed = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val queue = EngineWorkQueue(scope)

        queue.launch {
            try {
                started.complete(Unit)
                awaitCancellation()
            } finally {
                events += "cancelled"
            }
        }
        started.await()
        queue.close {
            events += "closed"
            closed.complete(Unit)
        }
        closed.await()

        assertEquals(listOf("cancelled", "closed"), events)
    }

    @Test fun queuedWorkCanBeCancelledWithoutRunning() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val queuedRan = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val queue = EngineWorkQueue(scope)
        queue.launch { started.complete(Unit); awaitCancellation() }
        started.await()
        queue.launch { queuedRan.complete(Unit) }
        queue.cancelActive()
        kotlinx.coroutines.withTimeoutOrNull(100) { queuedRan.await() }
        org.junit.Assert.assertFalse(queuedRan.isCompleted)
        scope.cancel()
    }
}
