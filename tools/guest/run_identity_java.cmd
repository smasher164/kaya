@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem NO ASSET LINE HERE ANY MORE: the guest names the mark
rem `asset("icons/kaya-mark.png")` and the core resolves it out
rem of the root the deploy stages and names machine-wide in
rem KAYA_ASSET_DIR — the typeface scene's rule, one asset over.
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\identity_java 2>nul
mkdir C:\kaya\legs\identity_java\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\identity_java\state
set KAYA_SELFTEST=identity
set KAYA_VERB_TRACE=C:\kaya\flightrec\identity_java-vtrace.txt
rem ms-appx resolves against the PROCESS exe's directory: place
rem kaya's minimal resources.pri beside java.exe (idempotent).
copy /y C:\kaya\resources.pri "C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot\bin\resources.pri" > nul
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_identity_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_java.txt
