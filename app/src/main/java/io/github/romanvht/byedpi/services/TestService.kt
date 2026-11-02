package io.github.romanvht.byedpi.services

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.AtomicFile
import android.util.Log
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.github.romanvht.byedpi.R
import io.github.romanvht.byedpi.activities.TestActivity
import io.github.romanvht.byedpi.data.*
import io.github.romanvht.byedpi.utility.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

class TestService : Service() {

    companion object {
        private const val TAG = "TestService"
        private const val CHANNEL = "Proxy test"
        private const val RESULTS_FILE = "proxy_test_results.json"
        private const val NOTIFICATION_ID = 4
        // AutoDPI
        const val AUTO_WINNER_KEY = "autodpi_winner"
        const val AUTO_SCORE_KEY = "autodpi_score"
        private const val AUTO_FINALISTS = 10
        private const val AUTO_ROUNDS = 3
        private val mutableState = MutableStateFlow(TestState())
        private val resultsLock = Any()
        val state: StateFlow<TestState> = mutableState.asStateFlow()
        val isRunning: Boolean
            get() = state.value.isRunning

        fun start(context: Context, auto: Boolean = false, forceFull: Boolean = false) {
            if (isRunning) return
            ServiceManager.refresh(context)
            val previous = state.value
            mutableState.value = previous.copy(
                runId = previous.runId + 1,
                isRunning = true,
                isStopping = false,
                currentStrategy = 0,
                failed = false,
                wasInterrupted = false,
                auto = auto,
                forceFull = forceFull,
                phase = 0,
                phaseProgress = 0,
                phaseTotal = 0,
                blockedCount = -1,
                winner = null,
            )
            try {
                ContextCompat.startForegroundService(context, Intent(context, TestService::class.java).setAction(START_ACTION))
            } catch (e: Exception) {
                mutableState.value = previous.copy(failed = true)
                Log.e(TAG, "Failed to start proxy tests", e)
            }
        }

        fun stop() {
            if (!isRunning) return
            mutableState.value = state.value.copy(isStopping = true)
        }

        /** AutoDPI: returns the winning command once after an auto run finished, then clears it. */
        fun consumeWinner(): String? {
            val current = state.value
            if (current.isRunning) return null
            val winner = current.winner ?: return null
            mutableState.value = current.copy(winner = null)
            return winner
        }

        suspend fun awaitStopped() {
            state.first { !it.isRunning }
        }

        suspend fun loadResults(context: Context) {
            val previous = state.value
            if (previous.isLoaded || previous.isRunning) return
            val app = context.applicationContext
            val loaded = withContext(Dispatchers.IO) {
                val results = try {
                    synchronized(resultsLock) {
                        AtomicFile(File(app.filesDir, RESULTS_FILE)).openRead().bufferedReader().use { reader ->
                            val type = object : TypeToken<List<StrategyResult>>() {}.type
                            Gson().fromJson<List<StrategyResult>>(reader, type) ?: emptyList()
                        }
                    }
                } catch (_: Exception) {
                    emptyList()
                }
                previous.copy(
                    isLoaded = true,
                    strategies = results,
                    wasInterrupted = app.getPreferences().getBoolean("is_test_running", false),
                )
            }
            withContext(Dispatchers.Main.immediate) {
                if (mutableState.compareAndSet(previous, loaded)) {
                    app.getPreferences().edit { putBoolean("is_test_running", false) }
                }
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val gson = Gson()
    private val engineMutex = Mutex()
    private var engine: NativeEngine? = null
    private var testJob: Job? = null
    private var lastStartId = 0
    private var destroyed = false
    private var notifiedStrategy = -1
    private var notifiedCompleted = -1

    override fun onCreate() {
        super.onCreate()
        registerNotificationChannel(this, CHANNEL, R.string.title_test)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            START_ACTION -> {
                try {
                    startForeground()
                    if (!isRunning) {
                        @Suppress("DEPRECATION")
                        stopForeground(true)
                        stopSelfResult(startId)
                    } else if (testJob == null) {
                        startTesting()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to show proxy test notification", e)
                    if (testJob == null) {
                        mutableState.value = state.value.copy(isRunning = false, isStopping = false, failed = true)
                        stopSelfResult(startId)
                    } else {
                        stop()
                    }
                }
            }
            STOP_ACTION -> {
                stop()
                if (testJob == null) stopSelfResult(startId)
            }
            else -> if (testJob == null) stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        if (testJob != null) stop()
        scope.cancel()
        super.onDestroy()
    }

    private fun startTesting() {
        val previous = state.value.copy(isRunning = false, isStopping = false)
        testJob = scope.launch(start = CoroutineStart.LAZY) {
            val testingJob = coroutineContext.job
            val auto = state.value.auto
            val forceFull = state.value.forceFull
            var winner: String? = null
            var settings: TestSettings? = null
            var currentStrategy: StrategyResult? = null
            var prepared = false
            var failed = false
            val strategies = mutableListOf<StrategyResult>()
            val stopWatcher = launch {
                try {
                    state.first { it.isStopping }
                    testingJob.cancel()
                } finally {
                    stopEngine()
                }
            }

            try {
                if (state.value.isStopping) {
                    throw CancellationException("Proxy test stopped")
                }
                val options = withContext(Dispatchers.IO) { loadSettings() }
                settings = options
                if (options.sites.isEmpty()) {
                    Toast.makeText(this@TestService, R.string.test_settings_domain_empty, Toast.LENGTH_LONG).show()
                    return@launch
                }
                strategies.addAll(options.commands.map { StrategyResult(command = it) })
                prepared = true
                getPreferences().edit(commit = true) { putBoolean("is_test_running", true) }
                publish(strategies, 0)
                ServiceManager.waitStop()
                val configurations = withContext(Dispatchers.IO) {
                    options.commands.map { command ->
                        runCatching { testConfiguration(this@TestService, command, options.host, options.port) }
                    }
                }

                if (auto) {
                    winner = runAuto(options, strategies, configurations, forceFull)
                } else for ((index, strategy) in strategies.withIndex()) {
                    ensureActive()
                    currentStrategy = strategy
                    strategy.totalRequests = options.sites.size * options.requestsCount
                    publish(strategies, index + 1)
                    val configuration = configurations[index].getOrNull()
                    if (configuration == null || !checkStrategy(strategy, strategies, configuration, options)) {
                        resetStrategyResult(strategy, options)
                    }
                    strategy.isCompleted = true
                    publish(strategies)
                    saveResults(strategies)
                    stopEngine()
                    currentStrategy = null
                    delay(options.delaySec * 500L)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Failed to run proxy tests", e)
                failed = true
            } finally {
                stopWatcher.cancel()
                withContext(NonCancellable) {
                    mutableState.value = state.value.copy(isStopping = true)
                    settings?.let { options ->
                        currentStrategy?.takeIf { !it.isCompleted }?.let {
                            resetStrategyResult(it, options)
                            it.isCompleted = true
                        }
                    }
                    stopEngine()
                    if (prepared) {
                        try {
                            saveResults(strategies)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to save proxy test results", e)
                            failed = true
                        }
                        getPreferences().edit(commit = true) { putBoolean("is_test_running", false) }
                    }
                    testJob = null
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                    stopSelfResult(lastStartId)
                    mutableState.value = if (prepared) TestState(
                        runId = previous.runId,
                        isLoaded = true,
                        strategies = snapshot(strategies),
                        failed = failed,
                        auto = auto,
                        winner = winner,
                    ) else previous.copy(failed = failed)
                }
            }
        }
        testJob?.start()
    }

    private suspend fun checkStrategy(
        strategy: StrategyResult,
        strategies: List<StrategyResult>,
        configuration: Configuration,
        settings: TestSettings,
    ): Boolean {
        return try {
            val current = startEngine(configuration)
            supervisorScope {
                val engineExit = async { current.awaitExit() }
                val check = async {
                    delay(settings.delaySec * 500L)
                    val host = when (configuration.host) {
                        "0.0.0.0" -> "127.0.0.1"
                        "::", "[::]" -> "::1"
                        else -> configuration.host
                    }
                    SiteCheckUtils(host, configuration.port).checkSitesAsync(
                        sites = settings.sites,
                        requestsCount = settings.requestsCount,
                        requestTimeout = settings.requestTimeout,
                        concurrentRequests = settings.requestLimit,
                        fullLog = true,
                        onSiteChecked = { site, successCount, countRequests ->
                            withContext(Dispatchers.Main.immediate) {
                                strategy.currentProgress += countRequests
                                strategy.successCount += successCount
                                strategy.siteResults.add(SiteResult(site, successCount, countRequests))
                                publish(strategies)
                            }
                        },
                        onSiteTimed = { _, _, _, ms ->
                            withContext(Dispatchers.Main.immediate) {
                                strategy.successMs += ms
                            }
                        }
                    )
                    true
                }
                try {
                    select {
                        engineExit.onAwait { false }
                        check.onAwait { it }
                    }
                } finally {
                    engineExit.cancel()
                    check.cancel()
                }
            }
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            if (state.value.isStopping) throw CancellationException("Proxy test stopped")
            Log.e(TAG, "Proxy test engine failed", e)
            Toast.makeText(this, getString(R.string.failed_to_start, Sender.Proxy.name), Toast.LENGTH_SHORT).show()
            false
        }
    }

    /**
     * AutoDPI "find best & connect":
     * 1. quick check of the saved winner (skipped when forceFull)
     * 2. baseline without bypass to find the blocked sites
     * 3. every strategy on the blocked sites
     * 4. top strategies AUTO_ROUNDS times on all sites; most reliable, then fastest, wins
     * Returns the winning command (already applied to the settings) or null.
     */
    private suspend fun runAuto(
        options: TestSettings,
        strategies: MutableList<StrategyResult>,
        configurations: List<Result<Configuration>>,
        forceFull: Boolean,
    ): String? {
        val prefs = getPreferences()
        val sites = options.sites

        // 1. quick check of the saved winner
        val saved = prefs.getString(AUTO_WINNER_KEY, null)
        val savedScore = prefs.getInt(AUTO_SCORE_KEY, -1)
        if (!forceFull && !saved.isNullOrBlank() && savedScore > 0) {
            setPhase(1, 1, 1)
            val configuration = withContext(Dispatchers.IO) {
                runCatching { testConfiguration(this@TestService, saved, options.host, options.port) }.getOrNull()
            }
            if (configuration != null) {
                val probe = StrategyResult(command = saved)
                probe.totalRequests = sites.size * options.requestsCount
                checkStrategy(probe, strategies, configuration, options)
                stopEngine()
                if (probe.successCount >= savedScore) {
                    applyWinner(saved, savedScore)
                    return saved
                }
            }
        }

        // 2. baseline: which sites are blocked without any bypass
        setPhase(2, 1, 1)
        val baseline = SiteCheckUtils(options.host, options.port, direct = true).checkSitesAsync(
            sites = sites,
            requestsCount = 1,
            requestTimeout = options.requestTimeout,
            concurrentRequests = options.requestLimit,
            fullLog = false,
        )
        val blocked = baseline.filter { it.second == 0 }.map { it.first }
        val screenOptions = options.copy(sites = blocked.ifEmpty { sites })
        mutableState.value = state.value.copy(blockedCount = blocked.size)

        // 3. screening: every strategy on the blocked sites
        for ((index, strategy) in strategies.withIndex()) {
            currentCoroutineContext().ensureActive()
            setPhase(3, index + 1, strategies.size)
            strategy.totalRequests = screenOptions.sites.size * options.requestsCount
            publish(strategies, index + 1)
            val configuration = configurations[index].getOrNull()
            if (configuration == null || !checkStrategy(strategy, strategies, configuration, screenOptions)) {
                resetStrategyResult(strategy, screenOptions)
            }
            strategy.isCompleted = true
            publish(strategies)
            stopEngine()
            delay(options.delaySec * 500L)
        }

        // 4. final round: best strategies, several rounds, all sites
        val finalists = strategies.withIndex()
            .filter { it.value.successCount > 0 }
            .sortedWith(compareByDescending<IndexedValue<StrategyResult>> { it.value.successCount }
                .thenBy { it.value.avgMs })
            .take(AUTO_FINALISTS)
        if (finalists.isEmpty()) return null

        for ((position, item) in finalists.withIndex()) {
            val strategy = item.value
            setPhase(4, position + 1, finalists.size)
            strategy.successCount = 0
            strategy.successMs = 0
            strategy.currentProgress = 0
            strategy.siteResults.clear()
            strategy.totalRequests = sites.size * options.requestsCount * AUTO_ROUNDS
            strategy.isCompleted = false
            publish(strategies, item.index + 1)
            val configuration = configurations[item.index].getOrNull()
            if (configuration != null) {
                repeat(AUTO_ROUNDS) {
                    currentCoroutineContext().ensureActive()
                    checkStrategy(strategy, strategies, configuration, options)
                    stopEngine()
                    delay(options.delaySec * 500L)
                }
            }
            strategy.isCompleted = true
            publish(strategies)
        }

        val ranked = finalists.map { it.value }
            .sortedWith(compareByDescending<StrategyResult> { it.successCount }.thenBy { it.avgMs })
        ranked.forEachIndexed { rank, strategy -> strategy.autoRank = rank + 1 }
        publish(strategies)
        val best = ranked.first()
        if (best.successCount == 0) return null
        applyWinner(best.command, best.successCount / AUTO_ROUNDS)
        return best.command
    }

    /** AutoDPI: make the command the active strategy and remember it for the next quick check. */
    private suspend fun applyWinner(command: String, score: Int) {
        getPreferences().edit(commit = true) {
            putString(AUTO_WINNER_KEY, command)
            putInt(AUTO_SCORE_KEY, score)
            putString("byedpi_cmd_args", command)
            putBoolean("byedpi_enable_cmd_settings", true)
        }
        withContext(Dispatchers.IO) { HistoryUtils(this@TestService).addCommand(command) }
    }

    private fun setPhase(phase: Int, progress: Int, total: Int) {
        mutableState.value = state.value.copy(phase = phase, phaseProgress = progress, phaseTotal = total)
    }

    private suspend fun startEngine(configuration: Configuration): NativeEngine {
        if (state.value.isStopping) throw CancellationException("Proxy test stopped")
        val current = NativeEngine(applicationContext, Mode.Proxy, foreground = false)
        engine = current
        current.start(configuration)
        return current
    }

    private suspend fun stopEngine() = withContext(NonCancellable) {
        engineMutex.withLock {
            val current = engine ?: return@withLock
            var stopFailed = false
            while (true) {
                try {
                    current.stop()
                    engine = null
                    break
                } catch (e: Exception) {
                    if (!stopFailed) Log.e(TAG, "Failed to stop proxy test engine", e)
                    stopFailed = true
                    delay(500)
                }
            }
        }
    }

    private fun loadSettings(): TestSettings {
        val prefs = getPreferences()
        val userCommands = prefs.getBoolean("byedpi_proxytest_usercommands", false)
        val sniValue = prefs.getStringNotNull("byedpi_proxytest_sni", "google.com")
        val content = if (userCommands) prefs.getStringNotNull("byedpi_proxytest_commands", "")
        else assets.open("proxytest_strategies.list").bufferedReader().use { it.readText() }
        val commands = content.replace("{sni}", "\"${sniValue}\"").lines().map { it.trim() }.filter { it.isNotEmpty() }
        val host = prefs.getStringNotNull("byedpi_proxy_ip", "127.0.0.1")
        val port = prefs.getIntStringNotNull("byedpi_proxy_port", 1080)
        val delaySec = prefs.getIntStringNotNull("byedpi_proxytest_delay", 1).coerceAtLeast(0)
        val requestsCount = prefs.getIntStringNotNull("byedpi_proxytest_requests", 1).coerceAtLeast(1)
        val requestTimeout = prefs.getLongStringNotNull("byedpi_proxytest_timeout", 5).coerceAtLeast(1)
        val requestLimit = prefs.getIntStringNotNull("byedpi_proxytest_limit", 20).coerceAtLeast(1)
        DomainListUtils.syncLists(this)
        return TestSettings(DomainListUtils.getActiveDomains(this).toList(), commands, host, port,
            delaySec, requestsCount, requestTimeout, requestLimit)
    }

    private fun resetStrategyResult(strategy: StrategyResult, settings: TestSettings) {
        strategy.successCount = 0
        strategy.currentProgress = 0
        strategy.siteResults.clear()
        strategy.siteResults.addAll(settings.sites.map { SiteResult(it, 0, settings.requestsCount) })
    }

    private fun snapshot(strategies: List<StrategyResult>): List<StrategyResult> =
        strategies.map { it.copy(siteResults = it.siteResults.toMutableList()) }

    private suspend fun saveResults(strategies: List<StrategyResult>) {
        val results = snapshot(strategies)
        withContext(Dispatchers.IO) {
            synchronized(resultsLock) {
                val file = AtomicFile(File(filesDir, RESULTS_FILE))
                val output = file.startWrite()
                try {
                    output.write(gson.toJson(results).toByteArray(Charsets.UTF_8))
                    file.finishWrite(output)
                } catch (e: Exception) {
                    file.failWrite(output)
                    throw e
                }
            }
        }
    }

    private fun publish(strategies: List<StrategyResult>, currentStrategy: Int = state.value.currentStrategy) {
        mutableState.value = state.value.copy(isLoaded = true, strategies = snapshot(strategies), currentStrategy = currentStrategy)
        val completed = strategies.count { it.isCompleted }
        if (!destroyed && (notifiedStrategy != currentStrategy || notifiedCompleted != completed)) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification())
            notifiedStrategy = currentStrategy
            notifiedCompleted = completed
        }
    }

    private fun notification(): Notification {
        val value = state.value
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.title_test))
            .setContentText(getString(R.string.test_process, value.currentStrategy, value.strategies.size))
            .setProgress(value.strategies.size, value.strategies.count { it.isCompleted }, value.currentStrategy == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, TestActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .addAction(0, getString(R.string.test_stop), PendingIntent.getService(this, 0,
                Intent(this, TestService::class.java).setAction(STOP_ACTION), PendingIntent.FLAG_IMMUTABLE))
            .build()
    }

    private fun startForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        notifiedStrategy = state.value.currentStrategy
        notifiedCompleted = state.value.strategies.count { it.isCompleted }
    }
}
