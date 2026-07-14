package dev.kaya

import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlin.concurrent.thread

/**
 * KayaCompose: the Kotlin half of the Compose backend, the Android
 * sibling of KayaSwiftUI.swift. Plays the presentation role of kaya's
 * protocol over the JNI presentation surface:
 *
 *   kaya signal      -> snapshot state (recomposition renders)
 *   occurrence       <- Compose onClick -> KayaPresent.emitButtonClicked
 *   command SetText  -> KayaPresent.nextCommand (blocking pump) -> state write
 *
 * The command pump blocks in nextCommand on its own thread and hops to
 * the UI thread to write snapshot state — the doorbell equivalent, no
 * polling, no callbacks across the ABI.
 *
 * Milestone-0 grade: the scene is hardcoded here, exactly as it is in
 * every other backend. The scene-as-data interpreter arrives with the
 * reactive surface.
 */
object KayaModel {
    var labelText by mutableStateOf("Clicked 0 times")
}

object KayaCompose {
    const val WIDGET_BUTTON = 1L
    const val WIDGET_LABEL = 2L
    const val COMMAND_SET_TEXT = 1

    /**
     * Mount the milestone-0 scene and start the command pump. Call from
     * onCreate when [Kaya.nativeStart] returns [Kaya.PRESENT_GUEST].
     */
    @JvmStatic
    fun mount(activity: ComponentActivity) {
        startCommandPump(activity)
        activity.setContent { KayaRoot() }
        if (System.getenv("KAYA_SELFTEST") != null) startSelftest(activity)
    }

    private fun startCommandPump(activity: ComponentActivity) {
        thread(name = "kaya-compose-pump") {
            val command = KayaCommand()
            while (KayaPresent.nextCommand(command)) {
                if (command.kind == COMMAND_SET_TEXT && command.widgetId == WIDGET_LABEL) {
                    val text = command.text
                    activity.runOnUiThread { KayaModel.labelText = text }
                }
            }
        }
    }

    /**
     * Drives the round trip without a human, matching every backend's
     * selftest: emits the occurrence the Button onClick emits and
     * verifies the rendered model state. Results go to logcat; halt
     * rather than exit so no teardown hook races the render threads.
     */
    private fun startSelftest(activity: ComponentActivity) {
        thread(name = "kaya-selftest") {
            Thread.sleep(1500)
            KayaPresent.emitButtonClicked(WIDGET_BUTTON)
            Thread.sleep(300)
            KayaPresent.emitButtonClicked(WIDGET_BUTTON)
            Thread.sleep(700)
            activity.runOnUiThread {
                val text = KayaModel.labelText
                val code = if (text == "Clicked 2 times") {
                    Log.i("kaya", "KAYA_SELFTEST: OK ($text)")
                    0
                } else {
                    Log.e("kaya", "KAYA_SELFTEST: FAILED (label reads $text)")
                    1
                }
                activity.finishAndRemoveTask()
                Runtime.getRuntime().halt(code)
            }
        }
    }
}

/** The milestone-0 scene. */
@Composable
fun KayaRoot() {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Button(onClick = { KayaPresent.emitButtonClicked(KayaCompose.WIDGET_BUTTON) }) {
            Text("Click me")
        }
        Text(KayaModel.labelText)
    }
}
