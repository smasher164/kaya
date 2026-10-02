set -e
SDK=$ANDROID_HOME; BT=$SDK/build-tools/37.0.0; JAR=$SDK/platforms/android-36/android.jar
rm -rf out && mkdir -p out/classes out/dex
javac --release 21 -encoding UTF-8 -classpath $JAR -d out/classes src/dev/kaya/nfprobe/Probe.java
$BT/d8 --min-api 26 --lib $JAR --output out/dex out/classes/dev/kaya/nfprobe/*.class
$BT/aapt2 link -o out/base.apk --manifest AndroidManifest.xml -I $JAR
cd out && cp base.apk unsigned.apk && zip -q -j unsigned.apk dex/classes.dex && $BT/zipalign -f 4 unsigned.apk aligned.apk
[ -f ../probe.keystore ] || keytool -genkeypair -keystore ../probe.keystore -storepass probepass -keypass probepass -alias p -keyalg RSA -dname CN=probe -validity 30 >/dev/null 2>&1
$BT/apksigner sign --ks ../probe.keystore --ks-pass pass:probepass --out nfprobe.apk aligned.apk
ls -la nfprobe.apk
