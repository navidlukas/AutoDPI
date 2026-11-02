# Windows AutoDPI - developer notes

`make_strategies.py` regenerates `windows/AutoDPI/app/strategies.txt` from the
GoodbyeDPI settings and the Flowseal zapret presets:

```bash
git clone --depth 1 https://github.com/Flowseal/zapret-discord-youtube.git
python3 windows/dev/make_strategies.py zapret-discord-youtube windows/AutoDPI/app/strategies.txt
```

The program itself is plain batch (`windows/AutoDPI/app/autodpi.cmd`) and needs no build.
