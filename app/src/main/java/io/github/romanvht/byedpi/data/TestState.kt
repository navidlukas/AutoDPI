package io.github.romanvht.byedpi.data

data class TestState(
    val runId: Long = 0,
    val isLoaded: Boolean = false,
    val isRunning: Boolean = false,
    val isStopping: Boolean = false,
    val currentStrategy: Int = 0,
    val strategies: List<StrategyResult> = emptyList(),
    val failed: Boolean = false,
    val wasInterrupted: Boolean = false,
    // AutoDPI "find best & connect" mode
    val auto: Boolean = false,
    val forceFull: Boolean = false,
    val phase: Int = 0,          // 0 idle, 1 quick check, 2 baseline, 3 screening, 4 final round
    val phaseProgress: Int = 0,
    val phaseTotal: Int = 0,
    val blockedCount: Int = -1,
    val winner: String? = null,  // command to apply and connect, consumed by the UI
    val dnsProvider: String? = null,     // encrypted DNS server used for the test and the VPN
    val dnsBlockedCount: Int = 0,        // sites that only open with encrypted DNS
    val privateDnsHint: String? = null,  // suggest this Private DNS name (provider fakes DNS answers)
)
