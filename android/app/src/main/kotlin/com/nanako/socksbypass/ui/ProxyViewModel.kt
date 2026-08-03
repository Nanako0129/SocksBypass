package com.nanako.socksbypass.ui

import android.app.Application
import android.content.Intent
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nanako.socksbypass.network.LocalEndpointScanner
import com.nanako.socksbypass.service.ProxyForegroundService
import com.nanako.socksbypass.service.ProxyStatus
import com.nanako.socksbypass.service.ProxyUiState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

data class ScreenState(
    val proxy: ProxyUiState = ProxyUiState(),
    val endpoints: List<LocalEndpointScanner.Endpoint> = emptyList(),
    val selectedAddress: String? = null,
    val port: Int = ProxyForegroundService.DEFAULT_PORT,
    /** API 33+: false until POST_NOTIFICATIONS granted (required for visible FGS). */
    val notificationsAllowed: Boolean = true,
)

class ProxyViewModel(app: Application) : AndroidViewModel(app) {
    private val _state = MutableStateFlow(ScreenState())
    val state: StateFlow<ScreenState> = _state.asStateFlow()

    private var lastSample: Pair<Long, Long>? = null
    private var lastSampleAt: Long = 0L

    private val listener: (ProxyUiState) -> Unit = { ui ->
        _state.update { current ->
            val now = System.currentTimeMillis()
            val prev = lastSample
            var upRate = current.proxy.uploadRate
            var downRate = current.proxy.downloadRate
            if (prev != null && lastSampleAt > 0) {
                val dt = (now - lastSampleAt).coerceAtLeast(1) / 1000.0
                upRate = ((ui.uploadBytes - prev.first).coerceAtLeast(0) / dt).toLong()
                downRate = ((ui.downloadBytes - prev.second).coerceAtLeast(0) / dt).toLong()
            }
            lastSample = ui.uploadBytes to ui.downloadBytes
            lastSampleAt = now
            current.copy(
                proxy = ui.copy(uploadRate = upRate, downloadRate = downRate),
            )
        }
    }

    init {
        ProxyForegroundService.addListener(listener)
        refreshEndpoints()
        viewModelScope.launch {
            while (true) {
                delay(2_000)
                if (_state.value.proxy.status == ProxyStatus.Stopped) {
                    refreshEndpoints()
                }
            }
        }
    }

    fun refreshEndpoints() {
        val list = LocalEndpointScanner.scanPrivateIpv4()
        _state.update { current ->
            val selected = current.selectedAddress
                ?.takeIf { addr -> list.any { it.address == addr } }
                ?: list.firstOrNull()?.address
            current.copy(endpoints = list, selectedAddress = selected)
        }
    }

    fun selectAddress(address: String) {
        _state.update { it.copy(selectedAddress = address) }
    }

    fun setPort(port: Int) {
        if (port in 1..65535) {
            _state.update { it.copy(port = port) }
        }
    }

    fun setNotificationsAllowed(allowed: Boolean) {
        _state.update { it.copy(notificationsAllowed = allowed) }
    }

    fun startProxy() {
        val s = _state.value
        if (!s.notificationsAllowed) return
        val addr = s.selectedAddress ?: return
        val port = s.port
        ProxyForegroundService.start(getApplication(), addr, port)
    }

    fun stopProxy() {
        ProxyForegroundService.stop(getApplication())
    }

    fun openNetworkSettings() {
        val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        getApplication<Application>().startActivity(intent)
    }

    fun openNotificationSettings() {
        val app = getApplication<Application>()
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        app.startActivity(intent)
    }

    override fun onCleared() {
        ProxyForegroundService.removeListener(listener)
        super.onCleared()
    }
}
