package com.nanako.socksbypass

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.nanako.socksbypass.service.ProxyStatus
import com.nanako.socksbypass.ui.ProxyViewModel
import com.nanako.socksbypass.ui.ScreenState
import java.util.Locale

class MainActivity : ComponentActivity() {
    private val viewModel: ProxyViewModel by viewModels()

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* optional; service still starts */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestNotificationPermission()
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val state by viewModel.state.collectAsState()
                    ProxyScreen(
                        state = state,
                        onRefresh = viewModel::refreshEndpoints,
                        onSelect = viewModel::selectAddress,
                        onStart = viewModel::startProxy,
                        onStop = viewModel::stopProxy,
                        onOpenSettings = viewModel::openNetworkSettings,
                    )
                }
            }
        }
    }

    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

@Composable
fun ProxyScreen(
    state: ScreenState,
    onRefresh: () -> Unit,
    onSelect: (String) -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val context = LocalContext.current
    val proxy = state.proxy
    val statusText = when (proxy.status) {
        ProxyStatus.Listening -> "LISTENING"
        ProxyStatus.Stopped -> "STOPPED"
        ProxyStatus.CellularUnavailable -> "CELLULAR UNAVAILABLE"
    }
    val endpoint = when {
        proxy.status != ProxyStatus.Stopped && proxy.bindHost.isNotBlank() ->
            "${proxy.bindHost}:${proxy.port}"
        state.selectedAddress != null ->
            "${state.selectedAddress}:${state.port}"
        else -> "—"
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("SocksBypass", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text(
            text = stringResource(R.string.exposure_warning),
            color = Color(0xFFB71C1C),
            style = MaterialTheme.typography.bodyMedium,
        )

        Labeled("Status", statusText)
        Labeled("Proxy", endpoint)
        Labeled("Upstream", proxy.upstreamLabel.ifBlank {
            if (proxy.cellularAvailable) "CELLULAR" else "CELLULAR UNAVAILABLE"
        })

        Text("Listen address", fontWeight = FontWeight.SemiBold)
        if (state.endpoints.isEmpty()) {
            Text("No private interface found. Enable personal hotspot, then refresh.")
            OutlinedButton(onClick = onOpenSettings) { Text("Open network settings") }
            OutlinedButton(onClick = onRefresh) { Text("Refresh addresses") }
        } else {
            state.endpoints.forEach { ep ->
                val selected = ep.address == state.selectedAddress
                Text(
                    text = "${ep.address}  (${ep.interfaceName})",
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(if (selected) Color(0x332E7D32) else Color.Transparent)
                        .clickable { onSelect(ep.address) }
                        .padding(8.dp),
                    fontFamily = FontFamily.Monospace,
                )
            }
            OutlinedButton(onClick = onRefresh) { Text("Refresh addresses") }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                val cm = context.getSystemService(ClipboardManager::class.java)
                cm?.setPrimaryClip(ClipData.newPlainText("proxy", endpoint))
            }) { Text("Copy") }
            if (proxy.status == ProxyStatus.Stopped) {
                Button(
                    onClick = onStart,
                    enabled = state.selectedAddress != null,
                ) { Text("Start") }
            } else {
                Button(onClick = onStop) { Text("Stop") }
            }
        }

        Labeled(
            "Traffic",
            "↑ ${formatRate(proxy.uploadRate)}   ↓ ${formatRate(proxy.downloadRate)}\n" +
                "↑ ${formatBytes(proxy.uploadBytes)}     ↓ ${formatBytes(proxy.downloadBytes)}",
        )
        Labeled("Sessions", "TCP ${proxy.activeTcp} · UDP ${proxy.activeUdp}")

        Text("Activity", fontWeight = FontWeight.SemiBold)
        proxy.activity.take(12).forEach { line ->
            Text(line, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Labeled(label: String, value: String) {
    Column {
        Text(label, fontWeight = FontWeight.SemiBold)
        Text(value, fontFamily = FontFamily.Monospace)
    }
}

private fun formatBytes(value: Long): String {
    if (value < 1024) return "$value B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var v = value.toDouble()
    var i = -1
    do {
        v /= 1024.0
        i++
    } while (v >= 1024 && i < units.lastIndex)
    return String.format(Locale.US, "%.1f %s", v, units[i])
}

private fun formatRate(bytesPerSec: Long): String = "${formatBytes(bytesPerSec)}/s"
