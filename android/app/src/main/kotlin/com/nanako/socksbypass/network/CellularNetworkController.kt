package com.nanako.socksbypass.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.nanako.socksbypass.core.UpstreamNetwork
import com.nanako.socksbypass.core.UpstreamUnavailableException
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference

/**
 * Acquires a cellular [Network] and exposes it as an [UpstreamNetwork].
 * Fail-closed: when cellular is gone, [isAvailable] is false and create/resolve throw.
 */
class CellularNetworkController(
    context: Context,
) : UpstreamNetwork {
    private val connectivity = context.applicationContext
        .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val cellular = AtomicReference<Network?>(null)

    @Volatile
    var validated: Boolean = false
        private set

    @Volatile
    var metered: Boolean = true
        private set

    var onAvailabilityChanged: ((Boolean) -> Unit)? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            cellular.set(network)
            refreshCaps(network)
            onAvailabilityChanged?.invoke(true)
        }

        override fun onLost(network: Network) {
            cellular.compareAndSet(network, null)
            if (cellular.get() == null) {
                validated = false
                onAvailabilityChanged?.invoke(false)
            }
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (cellular.get() == network) {
                refreshCaps(network, caps)
            }
        }
    }

    private var requested = false

    fun start() {
        if (requested) return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, callback)
        requested = true
    }

    fun stop() {
        if (!requested) return
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
        requested = false
        cellular.set(null)
        validated = false
        onAvailabilityChanged?.invoke(false)
    }

    override val isAvailable: Boolean
        get() = cellular.get() != null

    fun currentNetwork(): Network? = cellular.get()

    override fun resolve(host: String): List<InetAddress> {
        val network = cellular.get() ?: throw UpstreamUnavailableException()
        return network.getAllByName(host).toList()
    }

    override fun createTcpSocket(): Socket {
        val network = cellular.get() ?: throw UpstreamUnavailableException()
        return network.socketFactory.createSocket()
    }

    override fun createUdpSocket(): DatagramSocket {
        val network = cellular.get() ?: throw UpstreamUnavailableException()
        val socket = DatagramSocket()
        network.bindSocket(socket)
        return socket
    }

    private fun refreshCaps(network: Network, caps: NetworkCapabilities? = null) {
        val c = caps ?: connectivity.getNetworkCapabilities(network) ?: return
        validated = c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        metered = !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
