package com.example.easytier_pro_app

import java.util.ArrayDeque

class EasyTierServiceEventBuffer(private val maxSize: Int) {
    private val events = ArrayDeque<Map<String, Any?>>()

    init {
        require(maxSize > 0) { "maxSize must be positive" }
    }

    fun add(event: Map<String, Any?>): Boolean {
        synchronized(events) {
            val dropped = events.size >= maxSize
            if (dropped) {
                events.removeFirst()
            }
            events.addLast(event)
            return dropped
        }
    }

    fun drain(): List<Map<String, Any?>> {
        synchronized(events) {
            if (events.isEmpty()) {
                return emptyList()
            }
            val drained = events.toList()
            events.clear()
            return drained
        }
    }
}
