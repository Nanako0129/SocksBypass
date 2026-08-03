package com.nanako.socksbypass.core

import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.ConcurrentHashMap

class TrafficCounters(private val enabled: Boolean = true) {
    enum class Direction { Upload, Download }

    data class Snapshot(
        val uploadBytes: Long,
        val downloadBytes: Long,
        val activeTcp: Int,
        val activeUdp: Int,
    ) {
        val activeTotal: Int get() = activeTcp + activeUdp
    }

    private val uploadBytes = AtomicLong(0)
    private val downloadBytes = AtomicLong(0)
    private val activeSessions = ConcurrentHashMap.newKeySet<UUID>()
    private val activeAssociations = ConcurrentHashMap.newKeySet<UUID>()

    fun sessionOpened(id: UUID) {
        if (!enabled) return
        activeSessions.add(id)
    }

    fun sessionClosed(id: UUID) {
        if (!enabled) return
        activeSessions.remove(id)
    }

    fun associationOpened(id: UUID) {
        if (!enabled) return
        activeAssociations.add(id)
    }

    fun associationClosed(id: UUID) {
        if (!enabled) return
        activeAssociations.remove(id)
    }

    fun closeAllSessions() {
        activeSessions.clear()
        activeAssociations.clear()
    }

    fun recordCommitted(byteCount: Int, direction: Direction) {
        if (!enabled || byteCount <= 0) return
        val amount = byteCount.toLong()
        when (direction) {
            Direction.Upload -> uploadBytes.updateAndGet { addSaturating(it, amount) }
            Direction.Download -> downloadBytes.updateAndGet { addSaturating(it, amount) }
        }
    }

    fun snapshot(): Snapshot = Snapshot(
        uploadBytes = uploadBytes.get(),
        downloadBytes = downloadBytes.get(),
        activeTcp = activeSessions.size,
        activeUdp = activeAssociations.size,
    )

    private fun addSaturating(current: Long, amount: Long): Long {
        val sum = current + amount
        return if (sum < current) Long.MAX_VALUE else sum
    }
}
