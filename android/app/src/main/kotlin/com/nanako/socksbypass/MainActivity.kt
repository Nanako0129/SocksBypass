package com.nanako.socksbypass

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import com.nanako.socksbypass.ui.ProxyScreen
import com.nanako.socksbypass.ui.ProxyViewModel
import com.nanako.socksbypass.ui.theme.SocksTheme

class MainActivity : ComponentActivity() {
    private val viewModel: ProxyViewModel by viewModels()

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        viewModel.setNotificationsAllowed(granted)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        refreshNotificationPermission(requestIfMissing = true)
        setContent {
            SocksTheme {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .safeDrawingPadding(),
                ) {
                    val state by viewModel.state.collectAsState()
                    ProxyScreen(
                        state = state,
                        onRefresh = viewModel::refreshEndpoints,
                        onSelect = viewModel::selectAddress,
                        onStart = viewModel::startProxy,
                        onStop = viewModel::stopProxy,
                        onOpenSettings = viewModel::openNetworkSettings,
                        onRequestNotifications = {
                            refreshNotificationPermission(requestIfMissing = true)
                        },
                        onOpenNotificationSettings = viewModel::openNotificationSettings,
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-check after user returns from Settings; do not re-spam the dialog.
        refreshNotificationPermission(requestIfMissing = false)
    }

    private fun refreshNotificationPermission(requestIfMissing: Boolean) {
        if (Build.VERSION.SDK_INT < 33) {
            viewModel.setNotificationsAllowed(true)
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        viewModel.setNotificationsAllowed(granted)
        if (!granted && requestIfMissing) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
