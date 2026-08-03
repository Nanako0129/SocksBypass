package com.nanako.socksbypass.core

import java.net.InetAddress

/**
 * Filters upstream destinations for CONNECT / UDP ASSOCIATE.
 * Production refuses destinations that would not (or must not) leave the phone
 * via cellular, and that turn NO AUTH into a local port scanner.
 */
fun interface DestinationPolicy {
    fun isAllowed(address: InetAddress): Boolean

    companion object {
        /**
         * Default for the app: no loopback, link-local, unspecified, or multicast.
         * Site-local (RFC1918) remains allowed so lab targets on private nets work
         * when reached via cellular routing (rare) or when tests inject ALLOW_ALL.
         */
        val PRODUCTION: DestinationPolicy = DestinationPolicy { addr ->
            !addr.isLoopbackAddress &&
                !addr.isLinkLocalAddress &&
                !addr.isAnyLocalAddress &&
                !addr.isMulticastAddress
        }

        /** Unit-test harness only — never wire into the Android app. */
        val ALLOW_ALL: DestinationPolicy = DestinationPolicy { true }
    }
}

class DestinationDeniedException(message: String = "destination not allowed") :
    Exception(message)
