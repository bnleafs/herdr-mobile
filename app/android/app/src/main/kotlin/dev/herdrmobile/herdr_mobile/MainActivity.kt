package dev.herdrmobile.herdr_mobile

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.ViewTreeObserver
import com.dexterous.flutterlocalnotifications.ForegroundService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Flutter syncs the keyboard's animation with the window's insets from API 30
 * (`TextInputPlugin` installs `ImeSyncDeferringInsetsCallback` there) and stops
 * taking the navigation bar off them from API 35. Only in between is the bug
 * below reachable; everywhere else this activity is a plain `FlutterActivity`.
 */
private val engineSubtractsNavigationBar = Build.VERSION.SDK_INT in 30..34

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!engineSubtractsNavigationBar) return
        // Flutter clears the flag when Dart asks for edge to edge, and on every
        // resume; whenever the window lays out, put it back.
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener(
            ViewTreeObserver.OnGlobalLayoutListener { layoutBehindNavigationBar() },
        )
    }

    override fun onPostResume() {
        super.onPostResume()
        if (engineSubtractsNavigationBar) layoutBehindNavigationBar()
    }

    /**
     * The quiet "Watching N agents" notice (flutter_local_notifications'
     * service) stands for the connections this activity's Dart isolate holds.
     * Whenever the activity goes for good (finished by Back, or destroyed by
     * the system while the app is in the background: `isFinishing` is false
     * then, and the service would keep an empty process alive) the isolate and
     * its connections are gone, so the notice must go too. A configuration
     * change recreates the activity around the same engine: that one stays.
     */
    override fun onDestroy() {
        if (!isChangingConfigurations) stopService(Intent(this, ForegroundService::class.java))
        super.onDestroy()
    }

    /**
     * Back at the app's root would finish the activity and end the engine. While
     * agents are watched Dart asks for the task to go to the background
     * instead, as Home does.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.herdrmobile/task")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> result.success(moveTaskToBack(true))
                    // Android 13+ confirms a clipboard write itself.
                    "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.herdrmobile/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> installApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Hands a downloaded release APK to Android's PackageInstaller session API.
     * On Android 12+ (API 31+), with UPDATE_PACKAGES_WITHOUT_USER_ACTION declared,
     * updates can be installed without user action when updating itself. If user
     * action is required (or on policy refusal / older Android), the session
     * broadcasts STATUS_PENDING_USER_ACTION to [UpdateInstallReceiver], which
     * launches the system confirmation intent immediately.
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        // Only a verified, renamed release APK: never a `.part` or another file.
        if (path == null || !File(path).name.matches(Regex("herdr-mobile-\\d+\\.\\d+\\.\\d+\\.apk"))) {
            return result.error("install", "There is no update file to install. Download it again.", null)
        }
        val file = File(path)
        if (!file.exists()) {
            return result.error("install", "The update file is not where herdr keeps updates. Download it again.", null)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
                )
                return result.success("needsPermission")
            }
            Thread {
                var session: PackageInstaller.Session? = null
                try {
                    val installer = packageManager.packageInstaller
                    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                    params.setAppPackageName(packageName)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                    }
                    val sessionId = installer.createSession(params)
                    session = installer.openSession(sessionId)
                    session.openWrite("package", 0, file.length()).use { out ->
                        file.inputStream().use { input ->
                            input.copyTo(out)
                        }
                        session.fsync(out)
                    }
                    val intent = Intent(this, UpdateInstallReceiver::class.java)
                    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    } else {
                        PendingIntent.FLAG_UPDATE_CURRENT
                    }
                    val pendingIntent = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                    session.commit(pendingIntent.intentSender)
                    session.close()
                    runOnUiThread { result.success("started") }
                } catch (e: Exception) {
                    try {
                        session?.abandon()
                    } catch (_: Exception) {}
                    runOnUiThread {
                        result.error("install", e.message ?: "Android couldn’t open the installer.", null)
                    }
                }
            }.start()
        } catch (e: Exception) {
            result.error("install", e.message ?: "Android couldn’t open the installer.", null)
        }
    }

    /**
     * Flutter 3.44+ draws edge to edge with `setDecorFitsSystemWindows(false)`
     * and leaves the legacy layout flags at 0. Its keyboard animation sync still
     * reads "no LAYOUT_HIDE_NAVIGATION" as "the navigation bar is not under the
     * view" and takes the bar's height off every animated inset, while the
     * inset it reports once the keyboard has settled keeps it. The layout then
     * runs one bar's height (48 dp here) short during the whole animation and
     * snaps on the last frame (flutter/flutter#190974, #191094).
     *
     * The window already extends under the bar, so the flag changes no layout
     * (the padding the app sees is the same with and without it): it only makes
     * the engine report the system's insets as they are. Remove it once an
     * engine with the fix ships.
     */
    @Suppress("DEPRECATION")
    private fun layoutBehindNavigationBar() {
        val decor = window.decorView
        val flags = decor.systemUiVisibility
        if (flags and View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION == 0) {
            decor.systemUiVisibility = flags or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }
}

/**
 * Handles callbacks from [PackageInstaller.Session.commit].
 * When Android asks for confirmation (user action required), launches the system confirmation dialog.
 * When the install succeeds, the app process is replaced by the new version.
 * If the install fails, records the status code and error message in SharedPreferences for Dart.
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                try {
                    context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean("flutter.update.pendingUserAction.v1", true)
                        .apply()
                } catch (_: Exception) {}
                val confirmIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirmIntent?.let {
                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        context.startActivity(it)
                    } catch (_: Exception) {}
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // Success: the process is replaced by the installed version.
            }
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Status $status"
                try {
                    context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit()
                        .putInt("flutter.update.installStatus.v1", status)
                        .putString("flutter.update.installError.v1", message)
                        .remove("flutter.update.pendingUserAction.v1")
                        .apply()
                } catch (_: Exception) {}
            }
        }
    }
}
