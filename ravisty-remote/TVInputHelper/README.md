# Fast input helper

`ravisty-input.jar` is a small DEX JAR for the existing authorized ADB shell. It starts one `app_process` for the lifetime of the remote connection and injects allowed remote key events. It does not open a network port, install an APK, register an Android service, or start on boot. EOF terminates the process.

SHA-256 of the supplied JAR:

```text
7811faef4a787dcf80f9f701716da58c98d84fb5ec8c72f55416beaee6574fe7
```

Place it on the TV once using an already authorized computer:

```sh
adb -s 192.168.0.121:5555 push ravisty-input.jar /data/local/tmp/ravisty-input.jar
adb -s 192.168.0.121:5555 shell chmod 600 /data/local/tmp/ravisty-input.jar
```

The iPhone app opens this raw ADB service after connecting:

```text
exec:CLASSPATH=/data/local/tmp/ravisty-input.jar app_process /system/bin tv.ravisty.input.Main
```

Protocol is UTF-8 lines. Startup prints `READY 1`. A request `key <sequence> <keyCode>` produces `OK <sequence>` or `ERR <sequence> <reason>`. Sequence range is 1–4294967295. `ping` returns `PONG`; `exit` returns `BYE` and terminates. Input lines are capped at 100 characters; key codes are explicitly whitelisted in the source.

`OK` means Android accepted the DOWN/UP injection; it does not measure when an app finishes redrawing. A raw Wi-Fi probe on the configured BQ measured median 13.28 ms to this acknowledgement, versus roughly 1.9–2.0 seconds for a fresh `input keyevent` process. Real iPhone/network latency must still be checked after installation.

To rebuild with JDK and the official Android SDK build tools:

```sh
mkdir -p build/classes build/dex
javac --release 8 -encoding UTF-8 -cp "$ANDROID_JAR" -d build/classes src/tv/ravisty/input/Main.java
"$BUILD_TOOLS/d8" --release --min-api 23 --lib "$ANDROID_JAR" --output build/dex build/classes/tv/ravisty/input/*.class
jar cf build/ravisty-input.jar -C build/dex classes.dex
```

Set `ANDROID_JAR` to the SDK platform's `android.jar` and `BUILD_TOOLS` to its build-tools directory. The resulting archive hash can differ because JAR metadata includes build timestamps.
