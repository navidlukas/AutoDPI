# AutoDPI - one-tap DPI bypass tuner for Android and Windows

AutoDPI finds the DPI-bypass setting that works best on **your** network and switches it on:
it checks which test sites are blocked, tries every setting, re-tests the best 10 three
times on all sites, and keeps the most reliable (then fastest) one. The winner is
remembered per network (each Wi-Fi / mobile data), so next time only a quick check runs.

## Download

| Platform | File | How to use |
|---|---|---|
| Android 5+ | [AutoDPI.apk](https://github.com/navidlukas/AutoDPI/releases/download/latest/AutoDPI.apk) | Install, then tap **Find best & connect** (hold it to force a full re-test) |
| Windows 10/11 | [AutoDPI-Windows.zip](https://github.com/navidlukas/AutoDPI/releases/download/latest/AutoDPI-Windows.zip) | Unzip, edit `test_sites.txt`, double-click `1_START.cmd` |

- **Android** is a fork of [ByeByeDPI](https://github.com/romanvht/ByeByeDPI) (ByeDPI engine, no root needed), with 166 test strategies in 13 types; a full test usually takes a few minutes.
- **Windows** combines [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI), [zapret](https://github.com/bol-van/zapret) and the
  [Flowseal](https://github.com/Flowseal/zapret-discord-youtube) presets: 144 settings in 14 types (usually tested in 2-5 minutes), plain `.cmd`, portable. Source: [`windows/`](windows/).

**Encrypted DNS (automatic):** before testing, both versions check 15 DNS-over-HTTPS servers at once (Quad9,
Cloudflare, Google, AdGuard, Yandex, OpenDNS, Control D, DNS4EU, DNS.SB, CIRA Shield, CleanBrowsing,
Hurricane Electric, Switch, AliDNS, LibreDNS). The fastest one is used for every test and for browsing.
Android: every app's DNS is encrypted through the VPN, and the main screen shows the server in use.
Windows: the computer's DNS is switched to that server (fully encrypted on Windows 11; Chrome, Edge and
Firefox encrypt it on Windows 10). `6_RESET_to_defaults.cmd` puts the old DNS back.

If no setting works, the sites are probably blocked by IP address; only a VPN or proxy helps then.

---

<div align="center">
  <p>
    <img src="https://github.com/romanvht/ByeDPIAndroid/raw/master/.github/images/app.svg" alt="Логотип ByeDPI" width="200" />
  </p>
  <h1>ByeByeDPI Android</h1>
  <p>
    Русский |
    <a href="README-en.md">English</a> |
    <a href="README-tr.md">Türkçe</a>
  </p>
  <p>
    <a href="https://github.com/romanvht/ByeByeDPI/releases/latest"><img src="https://img.shields.io/github/v/release/romanvht/ByeByeDPI" alt="Latest Release" /></a>
    <a href="https://github.com/romanvht/ByeByeDPI/releases"><img src="https://img.shields.io/github/downloads/romanvht/ByeByeDPI/total" alt="Downloads" /></a>
    <a href="https://github.com/romanvht/ByeByeDPI/blob/master/LICENSE"><img src="https://img.shields.io/github/license/romanvht/ByeByeDPI" alt="License" /></a>
    <a href="https://github.com/romanvht/ByeByeDPI"><img src="https://img.shields.io/github/languages/code-size/romanvht/ByeByeDPI" alt="GitHub code size in bytes"/></a>
  </p>
</div>

Приложение для Android, которое локально запускает ByeDPI и перенаправляет весь трафик через него.

Для стабильной работы может потребоваться изменить настройки. Подробнее о различных настройках можно прочитать в [документации ByeDPI](https://github.com/hufrea/byedpi/blob/main/README.md).

Приложение не является VPN. Оно использует VPN-режим на Android для перенаправления трафика, но не передает ничего на удаленный сервер. Оно не шифрует трафик и не скрывает ваш IP-адрес.

У приложения есть единственный официальный сайт -> https://byebyedpi.xyz

---

### Возможности
* Автозапуск сервиса при старте устройства
* Сохранение списков параметров командной строки
* Улучшена совместимость с Android TV/BOX
* Раздельное туннелирование приложений
* Импорт/экспорт настроек

### Использование
* Для работы автозапуска активируйте пункт в настройках.
* Рекомендуется подключится один раз к VPN, чтобы принять запрос.
* После этого, при загрузке устройства, приложение автоматически запустит сервис в зависимости от настроек (VPN/Proxy)
* Комплексная инструкция от комьюнити [ByeByeDPI-Manual](https://byebyedpi.xyz)

### Сборка
1. Клонируйте репозиторий с сабмодулями:
```bash
git clone --recurse-submodules
```
2. Запустите скрипт сборки из корня репозитория:
```bash
./gradlew assembleRelease
```
3. APK будет в `app/build/outputs/apk/release/`

> P.S.: hev_socks5_tunnel не соберется под Windows, вам нужно будет использовать WSL

### Хеш подписи
SHA-256:
`77:45:10:75:AC:EA:40:64:06:47:5D:74:D4:59:88:3A:49:A6:40:51:FA:F3:2E:42:F7:18:F3:F9:77:7A:8D:FB`

### Зависимости
- [ByeDPI](https://github.com/hufrea/byedpi)
- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)

### Благодарность
- [hufrea](https://github.com/hufrea) - за [ByeDPI](https://github.com/hufrea/byedpi)
- [dovecoteescapee](https://github.com/dovecoteescapee) - за изначальную реализацию [ByeDPIAndroid](https://github.com/dovecoteescapee/ByeDPIAndroid)
