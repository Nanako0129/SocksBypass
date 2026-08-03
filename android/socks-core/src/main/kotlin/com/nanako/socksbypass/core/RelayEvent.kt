package com.nanako.socksbypass.core

/**
 * Redacted by construction: cases carry no peer address, hostname, port, or payload.
 */
sealed class RelayEvent {
    data object SessionOpened : RelayEvent()
    data object SessionClosed : RelayEvent()
    data object ConnectEstablished : RelayEvent()
    data class ConnectRejected(val reply: Int) : RelayEvent()
    data object UdpAssociated : RelayEvent()
    data object UdpAssociateFailed : RelayEvent()
    data object ListenerFailed : RelayEvent()
}
