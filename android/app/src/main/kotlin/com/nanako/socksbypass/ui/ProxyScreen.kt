package com.nanako.socksbypass.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nanako.socksbypass.R
import com.nanako.socksbypass.network.LocalEndpointScanner
import com.nanako.socksbypass.service.ProxyStatus
import com.nanako.socksbypass.ui.theme.SocksColors
import java.util.Locale

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
    val statusColor = when (proxy.status) {
        ProxyStatus.Listening -> SocksColors.Accent
        ProxyStatus.Stopped -> SocksColors.Stopped
        ProxyStatus.CellularUnavailable -> SocksColors.Amber
    }
    val endpoint = when {
        proxy.status != ProxyStatus.Stopped && proxy.bindHost.isNotBlank() ->
            "${proxy.bindHost}:${proxy.port}"
        state.selectedAddress != null ->
            "${state.selectedAddress}:${state.port}"
        else -> "—"
    }
    val upstream = proxy.upstreamLabel.ifBlank {
        if (proxy.cellularAvailable) "CELLULAR" else "CELLULAR UNAVAILABLE"
    }
    val running = proxy.status != ProxyStatus.Stopped

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SocksColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Hero
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = "SOCKS5",
                style = MaterialTheme.typography.labelSmall,
                color = SocksColors.TextMuted,
            )
            Text(
                text = "SocksBypass",
                style = MaterialTheme.typography.headlineLarge,
            )
            Text(
                text = "NO AUTH · CONNECT · UDP ASSOCIATE",
                style = MaterialTheme.typography.labelSmall,
                color = SocksColors.TextMuted,
            )
        }

        // Status chip
        StatusChip(label = statusText, color = statusColor)

        // Security warning — always visible, never dismissible (parity with iOS)
        Surface(
            color = SocksColors.WarningBg,
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = stringResource(R.string.exposure_warning),
                color = SocksColors.WarningText,
                style = MaterialTheme.typography.bodyMedium.copy(
                    color = SocksColors.WarningText,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.Medium,
                ),
                modifier = Modifier.padding(14.dp),
            )
        }

        // Endpoint card
        SectionCard(title = "PROXY") {
            Text(
                text = endpoint,
                fontFamily = FontFamily.Monospace,
                fontSize = 20.sp,
                fontWeight = FontWeight.Medium,
                color = SocksColors.TextPrimary,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = upstream,
                style = MaterialTheme.typography.bodySmall,
                color = if (proxy.status == ProxyStatus.CellularUnavailable ||
                    upstream.contains("UNAVAILABLE")
                ) {
                    SocksColors.Amber
                } else {
                    SocksColors.TextSecondary
                },
            )
            Spacer(Modifier.height(14.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                OutlinedButton(
                    onClick = {
                        val cm = context.getSystemService(ClipboardManager::class.java)
                        cm?.setPrimaryClip(ClipData.newPlainText("proxy", endpoint))
                    },
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp),
                    border = BorderStroke(1.dp, SocksColors.Border),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = SocksColors.TextPrimary,
                    ),
                ) {
                    Text("Copy")
                }
                Button(
                    onClick = if (running) onStop else onStart,
                    enabled = running || state.selectedAddress != null,
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (running) SocksColors.Danger else SocksColors.Accent,
                        contentColor = if (running) Color.White else Color(0xFF052E16),
                        disabledContainerColor = SocksColors.SurfaceElevated,
                        disabledContentColor = SocksColors.TextMuted,
                    ),
                ) {
                    Text(
                        text = if (running) "Stop" else "Start",
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }

        // Listen address
        SectionCard(title = "LISTEN ADDRESS") {
            if (state.endpoints.isEmpty()) {
                Text(
                    text = "No private interface found. Enable personal hotspot, then refresh.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = SocksColors.Amber,
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = onOpenSettings,
                        modifier = Modifier.heightIn(min = 48.dp),
                        border = BorderStroke(1.dp, SocksColors.Border),
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = SocksColors.TextPrimary,
                        ),
                    ) { Text("Network settings") }
                    OutlinedButton(
                        onClick = onRefresh,
                        modifier = Modifier.heightIn(min = 48.dp),
                        border = BorderStroke(1.dp, SocksColors.Border),
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = SocksColors.TextPrimary,
                        ),
                    ) { Text("Refresh") }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.endpoints.forEach { ep ->
                        AddressRow(
                            endpoint = ep,
                            selected = ep.address == state.selectedAddress,
                            enabled = !running,
                            onClick = { onSelect(ep.address) },
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                OutlinedButton(
                    onClick = onRefresh,
                    enabled = !running,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 48.dp),
                    border = BorderStroke(1.dp, SocksColors.Border),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = SocksColors.TextPrimary,
                    ),
                ) { Text("Refresh addresses") }
            }
        }

        // Metrics
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            MetricCard(
                label = "UPLOAD",
                primary = formatRate(proxy.uploadRate),
                secondary = formatBytes(proxy.uploadBytes),
                modifier = Modifier.weight(1f),
            )
            MetricCard(
                label = "DOWNLOAD",
                primary = formatRate(proxy.downloadRate),
                secondary = formatBytes(proxy.downloadBytes),
                modifier = Modifier.weight(1f),
            )
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            MetricCard(
                label = "TCP",
                primary = proxy.activeTcp.toString(),
                secondary = "sessions",
                modifier = Modifier.weight(1f),
            )
            MetricCard(
                label = "UDP",
                primary = proxy.activeUdp.toString(),
                secondary = "associations",
                modifier = Modifier.weight(1f),
            )
        }

        // Activity
        SectionCard(title = "ACTIVITY") {
            if (proxy.activity.isEmpty()) {
                Text("—", color = SocksColors.TextMuted, fontFamily = FontFamily.Monospace)
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    proxy.activity.take(14).forEachIndexed { index, line ->
                        if (index > 0) {
                            HorizontalDivider(color = SocksColors.Border.copy(alpha = 0.5f))
                        }
                        Text(
                            text = line,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                            color = SocksColors.TextSecondary,
                            lineHeight = 16.sp,
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
    }
}

@Composable
private fun StatusChip(label: String, color: Color) {
    val animated by animateColorAsState(color, animationSpec = tween(200), label = "status")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(SocksColors.Surface)
            .border(1.dp, SocksColors.Border, RoundedCornerShape(999.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .semantics { contentDescription = "Status $label" },
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(animated),
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            fontFamily = FontFamily.Monospace,
            color = SocksColors.TextPrimary,
        )
    }
}

@Composable
private fun SectionCard(
    title: String,
    content: @Composable () -> Unit,
) {
    Surface(
        color = SocksColors.Surface,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, SocksColors.Border),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelSmall,
                color = SocksColors.TextMuted,
            )
            Spacer(Modifier.height(10.dp))
            content()
        }
    }
}

@Composable
private fun MetricCard(
    label: String,
    primary: String,
    secondary: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = SocksColors.Surface,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, SocksColors.Border),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Text(label, style = MaterialTheme.typography.labelSmall, color = SocksColors.TextMuted)
            Spacer(Modifier.height(6.dp))
            Text(
                text = primary,
                fontFamily = FontFamily.Monospace,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = SocksColors.TextPrimary,
            )
            Text(
                text = secondary,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                color = SocksColors.TextMuted,
            )
        }
    }
}

@Composable
private fun AddressRow(
    endpoint: LocalEndpointScanner.Endpoint,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val bg by animateColorAsState(
        targetValue = if (selected) SocksColors.AccentDim else SocksColors.SurfaceElevated,
        animationSpec = tween(150),
        label = "addrBg",
    )
    val borderColor by animateColorAsState(
        targetValue = if (selected) SocksColors.Accent else SocksColors.Border,
        animationSpec = tween(150),
        label = "addrBorder",
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .border(1.dp, borderColor, RoundedCornerShape(12.dp))
            .then(
                if (enabled) {
                    Modifier.clickable(onClick = onClick)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 14.dp, vertical = 12.dp)
            .semantics {
                role = Role.RadioButton
                this.selected = selected
                contentDescription = "${endpoint.address} on ${endpoint.interfaceName}"
            },
    ) {
        Box(
            modifier = Modifier
                .size(18.dp)
                .clip(CircleShape)
                .border(
                    width = 2.dp,
                    color = if (selected) SocksColors.Accent else SocksColors.TextMuted,
                    shape = CircleShape,
                )
                .padding(3.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(SocksColors.Accent),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                text = endpoint.address,
                fontFamily = FontFamily.Monospace,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = SocksColors.TextPrimary,
            )
            Text(
                text = endpoint.interfaceName,
                style = MaterialTheme.typography.labelSmall,
                color = SocksColors.TextMuted,
            )
        }
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
