AutoDPI v2 - finds the best way past your provider's website blocking
=====================================================================
Portable: runs from this folder on Windows 10/11. Nothing to install, no
PowerShell, no browser needed. Windows will ask for administrator rights.

HOW TO USE
  1. Edit test_sites.txt - list blocked sites + 1-2 normal sites.
  2. Double-click 1_START.cmd and click Yes.
     First time: it tests all settings (about 15-20 minutes), then starts
     the best one in a minimised window. Start browsing.
  3. Next times: double-click 1_START.cmd again. It checks the saved setting
     in ~30 seconds and starts it (re-tests by itself if it stopped working).
     The best setting is remembered separately for each network (each Wi-Fi
     name, or wired), so a laptop moving between home and work keeps both.

THE FILES
  1_START.cmd                      start (tests first if needed)
  2_RETEST_find_best_setting.cmd   force a full new test
  3_STOP.cmd                       stop it
  4_AUTOSTART_with_Windows_ON.cmd  start the saved setting with Windows
  5_AUTOSTART_with_Windows_OFF.cmd turn that off
  6_RESET_to_defaults.cmd          reset test sites, saved settings and results
  test_sites.txt                   the sites used for testing
  results\                         saved settings per network, results.csv, last_test_log.txt
  app\                             the program (no need to open)

WHAT IT TESTS (app\strategies.txt - 144 settings, editable)
  - GoodbyeDPI (ValdikSS): 9 built-in modes + 35 combinations
  - zapret (bol-van) winws: 22 presets from Flowseal/zapret-discord-youtube
  - zapret blockcheck-style combinations: split / disorder / fake / seqovl /
    fakedsplit / hostfakesplit with different split points and fooling
    (badseq, badsum, md5sig, ts, ttl, autottl), plus decoys that mimic the
    real handshake (padencap, dupsid)
  Round 1 tests every setting on the blocked sites. The 10 best are then
  tested 3 times on all sites; most reliable, then fastest, wins.

NOTES
  - Close VPNs and other DPI tools while testing; avoid downloads.
  - Some zapret settings need TCP timestamps, so the test turns them on
    (netsh interface tcp set global timestamps=enabled). This is harmless.
  - If nothing works, the sites are blocked by IP address; only a VPN helps.
  - Antivirus may flag WinDivert (the packet driver both engines use).
    This is a known false alarm.
  - Settings (timeouts, number of finalists) are at the top of app\autodpi.cmd.
