AutoDPI v2 - finds the best way past your provider's website blocking
=====================================================================
Portable: runs from this folder on Windows 10/11. Nothing to install, no
PowerShell, no browser needed. Windows will ask for administrator rights.

HOW TO USE
  1. Edit test_sites.txt - list blocked sites + 1-2 normal sites.
  2. Double-click 1_START.cmd and click Yes.
     First time: it finds the best setting (usually 2-5 minutes), then starts
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
  6_RESET_to_defaults.cmd          reset test sites, saved settings, results and DNS
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
  The settings are grouped into 14 types (split, disorder, fake + badseq,
  fake + ts, ...). How a test runs:
  0. Encrypted DNS first: 16 DNS-over-HTTPS servers (Quad9, Cloudflare,
     Google, AdGuard, Yandex, OpenDNS, Control D, DNS4EU, DNS.SB, CIRA,
     CleanBrowsing, Hurricane Electric, Digitale Gesellschaft, Switch,
     AliDNS, LibreDNS) are checked at once and the fastest one is used
     for every site test. Sites that only open with encrypted DNS are shown
     as DNS-BLOCKED - switching DNS fixes them, no DPI setting needed.
  1. One setting of each type is tried on the blocked sites.
  2. Only the other settings of the types that worked are tried (if no type
     worked, everything else is tried). Testing stops once 3 settings open
     every blocked site.
  3. A setting is dropped as soon as the first blocked site fails, and only
     the first 16 KB of each page is loaded.
  4. The 5 best are tested 3 times on all sites; most reliable, then
     fastest, wins.

ENCRYPTED DNS FOR BROWSING
  After the test AutoDPI asks once (default Yes after 15 s) whether to use
  the chosen DNS server for browsing too. It then sets your network adapter's
  DNS to that server; Chrome, Edge and Windows 11 encrypt it automatically.
  6_RESET_to_defaults.cmd puts your original DNS settings back.

NOTES
  - Close VPNs and other DPI tools while testing; avoid downloads.
  - Some zapret settings need TCP timestamps, so the test turns them on
    (netsh interface tcp set global timestamps=enabled). This is harmless.
  - If nothing works, the sites are blocked by IP address; only a VPN helps.
  - Antivirus may flag WinDivert (the packet driver both engines use).
    This is a known false alarm.
  - Settings (timeouts, when to stop, number of finalists) are at the top
    of app\autodpi.cmd.
