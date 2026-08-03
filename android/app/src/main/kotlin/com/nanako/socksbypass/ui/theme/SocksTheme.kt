package com.nanako.socksbypass.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** OLED dark palette (ui-ux-pro-max / SocksBypass design system). */
object SocksColors {
    val Background = Color(0xFF020617)
    val Surface = Color(0xFF0F172A)
    val SurfaceElevated = Color(0xFF1E293B)
    val Border = Color(0xFF334155)
    val TextPrimary = Color(0xFFF8FAFC)
    val TextSecondary = Color(0xFF94A3B8)
    val TextMuted = Color(0xFF64748B)
    val Accent = Color(0xFF22C55E)
    val AccentDim = Color(0x3322C55E)
    val WarningBg = Color(0xFFFACC15)
    val WarningText = Color(0xFF0F172A)
    val Danger = Color(0xFFF87171)
    val Amber = Color(0xFFFBBF24)
    val Stopped = Color(0xFF64748B)
}

private val DarkScheme = darkColorScheme(
    primary = SocksColors.Accent,
    onPrimary = Color(0xFF052E16),
    secondary = SocksColors.SurfaceElevated,
    onSecondary = SocksColors.TextPrimary,
    background = SocksColors.Background,
    onBackground = SocksColors.TextPrimary,
    surface = SocksColors.Surface,
    onSurface = SocksColors.TextPrimary,
    surfaceVariant = SocksColors.SurfaceElevated,
    onSurfaceVariant = SocksColors.TextSecondary,
    outline = SocksColors.Border,
    error = SocksColors.Danger,
    onError = Color.White,
)

private val SocksTypography = Typography(
    headlineLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        letterSpacing = (-0.5).sp,
        color = SocksColors.TextPrimary,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        color = SocksColors.TextPrimary,
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
        color = SocksColors.TextPrimary,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        color = SocksColors.TextPrimary,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        color = SocksColors.TextSecondary,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 18.sp,
        color = SocksColors.TextPrimary,
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.6.sp,
        color = SocksColors.TextMuted,
    ),
    bodySmall = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        color = SocksColors.TextSecondary,
    ),
)

@Composable
fun SocksTheme(
    darkTheme: Boolean = isSystemInDarkTheme() || true,
    content: @Composable () -> Unit,
) {
    // Product is always dark OLED — matches iOS shell and design system.
    MaterialTheme(
        colorScheme = DarkScheme,
        typography = SocksTypography,
        content = content,
    )
}
