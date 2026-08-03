package com.nanako.socksbypass.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.nanako.socksbypass.core.RelayEvent
import com.nanako.socksbypass.core.Socks5Server
import com.nanako.socksbypass.core.TrafficCounters
import com.nanako.socksbypass.network.CellularNetworkController
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

/**
 * User-started foreground SOCKS proxy. Explicit intents only; START_NOT_STICKY.
 */
class ProxyForegroundService : Service() {
    private var cellular: CellularNetworkController? = null
    private var server: Socks5Server? = null
    private val counters = TrafficCounters(enabled = true)
    /** Pinned failure line so session-close spam during stop cannot evict it. */
    @Volatile
    private var stickyFailureLine: String? = null
    /** Coordinates async ListenerFailed with post-start LISTENING publish. */
    private val startLock = Any()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopProxy()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                val host = intent?.getStringExtra(EXTRA_BIND_HOST)
                val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
                if (host.isNullOrBlank()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startProxy(host, port)
            }
        }
        return START_NOT_STICKY
    }

    private fun startProxy(host: String, port: Int) {
        if (server != null) return
        stickyFailureLine = null

        // Refuse silent FGS if the user disabled the notification channel/app toggle
        // while leaving POST_NOTIFICATIONS granted (Codex P1).
        if (!NotificationFactory.areNotificationsVisiblyEnabled(this)) {
            stickyFailureLine = "notifications disabled — enable channel then Start"
            instanceState.set(
                ProxyUiState(
                    status = ProxyStatus.Stopped,
                    bindHost = host,
                    port = port,
                    activity = listOf(stickyFailureLine!!),
                ),
            )
            notifyListeners()
            stopSelf()
            return
        }

        // Promote to foreground *before* any work that can throw (5s FGS deadline).
        promoteForeground(starting = true, endpoint = null)
        instanceState.set(
            ProxyUiState(
                status = ProxyStatus.Starting,
                bindHost = host,
                port = port,
                activity = listOf("starting…"),
            ),
        )
        notifyListeners()

        try {
            val cell = CellularNetworkController(this).also { cellular = it }
            cell.onAvailabilityChanged = { available ->
                instanceState.updateAndGet {
                    it.copy(cellularAvailable = available)
                }
                notifyListeners()
            }
            cell.start()

            val socks = Socks5Server(
                bindHost = host,
                port = port,
                upstream = cell,
                counters = counters,
                eventHandler = { event ->
                    val line = describe(event)
                    if (event is RelayEvent.ListenerFailed) {
                        // Must fully tear down — UI-only STOPPED left sessions/FGS alive
                        // (open-relay after hotspot/interface drop). See dual-review C1.
                        synchronized(startLock) {
                            stickyFailureLine = line
                            instanceState.updateAndGet { state ->
                                state.copy(
                                    status = ProxyStatus.Stopped,
                                    activity = pinFailureActivity(line, state.activity),
                                )
                            }
                            notifyListeners()
                            stopProxyLocked()
                        }
                        stopSelf()
                        return@Socks5Server
                    }
                    // While tearing down after a sticky failure, do not let SessionClosed
                    // spam push the failure line out of the 50-entry activity window.
                    if (stickyFailureLine != null && event is RelayEvent.SessionClosed) {
                        return@Socks5Server
                    }
                    instanceState.updateAndGet { state ->
                        val log = (listOf(line) + state.activity).take(50)
                        when (event) {
                            is RelayEvent.ConnectEstablished -> state.copy(activity = log)
                            is RelayEvent.ConnectRejected -> state.copy(activity = log)
                            is RelayEvent.UdpAssociated -> state.copy(activity = log)
                            is RelayEvent.UdpAssociateFailed -> state.copy(activity = log)
                            else -> state.copy(activity = log)
                        }
                    }
                    notifyListeners()
                },
            )
            val bound = socks.start()
            // Publish server / LISTENING only if accept thread has not already failed
            // between start() returning and assignment (Codex P2 race).
            val published = synchronized(startLock) {
                if (stickyFailureLine != null) {
                    try {
                        socks.stop()
                    } catch (_: Exception) {
                    }
                    false
                } else {
                    server = socks
                    stickyFailureLine = null
                    val endpoint = "$host:$bound"
                    promoteForeground(starting = false, endpoint = endpoint)
                    instanceState.set(
                        ProxyUiState(
                            status = ProxyStatus.Listening,
                            bindHost = host,
                            port = bound,
                            cellularAvailable = cell.isAvailable,
                            upstreamLabel = upstreamLabel(cell),
                            activity = listOf("LISTENING"),
                        ),
                    )
                    notifyListeners()
                    statusTicker.start(this)
                    true
                }
            }
            if (!published) {
                stopSelf()
                return
            }
        } catch (e: Exception) {
            stickyFailureLine = "listener failed: ${e.javaClass.simpleName}"
            instanceState.set(
                ProxyUiState(
                    status = ProxyStatus.Stopped,
                    bindHost = host,
                    port = port,
                    cellularAvailable = cellular?.isAvailable ?: false,
                    activity = listOf(stickyFailureLine!!),
                ),
            )
            notifyListeners()
            stopProxy()
            stopSelf()
        }
    }

    private fun promoteForeground(starting: Boolean, endpoint: String?) {
        val notification = NotificationFactory.build(this, endpoint, starting = starting)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NotificationFactory.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NotificationFactory.NOTIFICATION_ID, notification)
        }
    }

    private fun stopProxy() {
        synchronized(startLock) {
            stopProxyLocked()
        }
    }

    /** Caller must hold [startLock] when racing with post-start publish. */
    private fun stopProxyLocked() {
        statusTicker.stop()
        try {
            server?.stop()
        } catch (_: Exception) {
        }
        server = null
        try {
            cellular?.stop()
        } catch (_: Exception) {
        }
        cellular = null
        counters.closeAllSessions()
        // Preserve bindHost/port + sticky failure; clear live upstream label (Codex P2/P3).
        instanceState.updateAndGet { prev ->
            val fail = stickyFailureLine
            val activity = if (fail != null) {
                pinFailureActivity(fail, prev.activity)
            } else {
                prev.activity
            }
            ProxyUiState(
                status = ProxyStatus.Stopped,
                bindHost = prev.bindHost,
                port = prev.port,
                cellularAvailable = false,
                upstreamLabel = "CELLULAR · …",
                activity = activity,
            )
        }
        notifyListeners()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun pinFailureActivity(failure: String, existing: List<String>): List<String> {
        val rest = existing.filterNot {
            it == failure || it == "session closed" || it == "session opened"
        }
        return (listOf(failure) + rest).take(50)
    }

    override fun onDestroy() {
        stopProxy()
        super.onDestroy()
    }

    private fun upstreamLabel(cell: CellularNetworkController): String {
        if (!cell.isAvailable) return "CELLULAR UNAVAILABLE"
        val v = if (cell.validated) "VALIDATED" else "UNVALIDATED"
        val m = if (cell.metered) "METERED" else "UNMETERED"
        return "CELLULAR · $v · $m"
    }

    private fun describe(event: RelayEvent): String = when (event) {
        RelayEvent.SessionOpened -> "session opened"
        RelayEvent.SessionClosed -> "session closed"
        RelayEvent.ConnectEstablished -> "CONNECT established"
        is RelayEvent.ConnectRejected -> "CONNECT rejected"
        RelayEvent.UdpAssociated -> "UDP ASSOCIATE established"
        RelayEvent.UdpAssociateFailed -> "UDP ASSOCIATE failed"
        RelayEvent.ListenerFailed -> "listener failed"
    }

    companion object {
        const val ACTION_START = "com.nanako.socksbypass.action.START"
        const val ACTION_STOP = "com.nanako.socksbypass.action.STOP"
        const val EXTRA_BIND_HOST = "bind_host"
        const val EXTRA_PORT = "port"
        const val DEFAULT_PORT = 9876

        private val instanceState = AtomicReference(ProxyUiState())
        private val listeners = CopyOnWriteArrayList<(ProxyUiState) -> Unit>()

        fun currentState(): ProxyUiState = instanceState.get()

        fun addListener(listener: (ProxyUiState) -> Unit) {
            listeners.add(listener)
            listener(instanceState.get())
        }

        fun removeListener(listener: (ProxyUiState) -> Unit) {
            listeners.remove(listener)
        }

        private fun notifyListeners() {
            val s = instanceState.get()
            listeners.forEach { it(s) }
        }

        fun start(context: Context, bindHost: String, port: Int = DEFAULT_PORT) {
            val intent = Intent(context, ProxyForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_BIND_HOST, bindHost)
                putExtra(EXTRA_PORT, port)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, ProxyForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        internal fun updateTraffic(snap: TrafficCounters.Snapshot, cellular: CellularNetworkController?) {
            instanceState.updateAndGet { state ->
                val status = when {
                    state.status == ProxyStatus.Stopped -> ProxyStatus.Stopped
                    state.status == ProxyStatus.Starting -> ProxyStatus.Starting
                    cellular != null && !cellular.isAvailable -> ProxyStatus.CellularUnavailable
                    else -> ProxyStatus.Listening
                }
                state.copy(
                    status = status,
                    uploadBytes = snap.uploadBytes,
                    downloadBytes = snap.downloadBytes,
                    activeTcp = snap.activeTcp,
                    activeUdp = snap.activeUdp,
                    cellularAvailable = cellular?.isAvailable ?: state.cellularAvailable,
                    upstreamLabel = if (cellular == null) state.upstreamLabel else {
                        if (!cellular.isAvailable) "CELLULAR UNAVAILABLE"
                        else {
                            val v = if (cellular.validated) "VALIDATED" else "UNVALIDATED"
                            val m = if (cellular.metered) "METERED" else "UNMETERED"
                            "CELLULAR · $v · $m"
                        }
                    },
                )
            }
            notifyListeners()
        }
    }

    private object statusTicker {
        @Volatile
        private var thread: Thread? = null

        fun start(service: ProxyForegroundService) {
            stop()
            thread = kotlin.concurrent.thread(name = "socks-status", isDaemon = true) {
                while (!Thread.currentThread().isInterrupted) {
                    val srv = service.server
                    val cell = service.cellular
                    if (srv != null) {
                        updateTraffic(srv.snapshot(), cell)
                    }
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
        }

        fun stop() {
            thread?.interrupt()
            thread = null
        }
    }
}

enum class ProxyStatus {
    Stopped,
    Starting,
    Listening,
    CellularUnavailable,
}

data class ProxyUiState(
    val status: ProxyStatus = ProxyStatus.Stopped,
    val bindHost: String = "",
    val port: Int = ProxyForegroundService.DEFAULT_PORT,
    val cellularAvailable: Boolean = false,
    val upstreamLabel: String = "CELLULAR · …",
    val uploadBytes: Long = 0,
    val downloadBytes: Long = 0,
    val uploadRate: Long = 0,
    val downloadRate: Long = 0,
    val activeTcp: Int = 0,
    val activeUdp: Int = 0,
    val activity: List<String> = emptyList(),
)
