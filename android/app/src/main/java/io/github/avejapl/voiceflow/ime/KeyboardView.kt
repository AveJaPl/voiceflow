package io.github.avejapl.voiceflow.ime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import io.github.avejapl.voiceflow.R

// The desktop overlay's matte monochrome, carried over.
private const val BG = 0xFF0A0A0B.toInt()
private const val SURFACE = 0xFF1A1A1D.toInt()
private const val TEXT = 0xFFF5F5F7.toInt()
private const val MUTED = 0xFF9A9AA2.toInt()

/**
 * The keyboard panel: one large microphone key, a status line, and the four
 * survival keys (switch keyboard, backspace, space, enter). Built in code —
 * a view this small doesn't earn a layout file.
 */
@SuppressLint("ViewConstructor")
class KeyboardView(context: Context) : LinearLayout(context) {

    var onMicTap: () -> Unit = {}
    var onBackspace: () -> Unit = {}
    var onSpace: () -> Unit = {}
    var onEnter: () -> Unit = {}
    var onSwitchKeyboard: () -> Unit = {}
    var onOpenApp: () -> Unit = {}

    private val status: TextView
    private val mic: FrameLayout
    private val micRing: View
    private val micIcon: TextView
    private var ready = false

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    init {
        orientation = VERTICAL
        setBackgroundColor(BG)
        setPadding(dp(16), dp(14), dp(16), dp(10))

        status = TextView(context).apply {
            setTextColor(MUTED)
            textSize = 13f
            gravity = Gravity.CENTER
            letterSpacing = 0.08f
            text = context.getString(R.string.status_idle)
        }
        addView(status, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        // -- mic key -------------------------------------------------------
        micRing = View(context).apply {
            background = circle(SURFACE, strokeColor = 0xFF33333A.toInt())
        }
        micIcon = TextView(context).apply {
            text = "🎙" // 🎙
            textSize = 30f
            gravity = Gravity.CENTER
        }
        mic = FrameLayout(context).apply {
            addView(micRing, FrameLayout.LayoutParams(dp(84), dp(84), Gravity.CENTER))
            addView(micIcon, FrameLayout.LayoutParams(dp(84), dp(84), Gravity.CENTER))
            setOnClickListener { onMicTap() }
        }
        addView(
            mic,
            LayoutParams(LayoutParams.MATCH_PARENT, dp(112)).apply { topMargin = dp(6) }
        )

        // -- bottom row ----------------------------------------------------
        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        row.addView(key("🌐", context.getString(R.string.key_switch)) { onSwitchKeyboard() })
        row.addView(key("⌫", context.getString(R.string.key_backspace)) { onBackspace() })
        row.addView(
            key("␣", context.getString(R.string.key_space)) { onSpace() },
            LayoutParams(0, dp(48), 2f)
        )
        row.addView(key("⏎", context.getString(R.string.key_enter)) { onEnter() })
        row.addView(key("⚙", context.getString(R.string.key_settings)) { onOpenApp() })
        addView(
            row,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(10)
            }
        )
    }

    private fun key(label: String, description: String, onTap: () -> Unit): TextView =
        TextView(context).apply {
            text = label
            contentDescription = description
            setTextColor(TEXT)
            textSize = 20f
            gravity = Gravity.CENTER
            background = pill(SURFACE)
            layoutParams = LayoutParams(dp(56), dp(48)).apply { marginEnd = dp(8) }
            setOnClickListener { onTap() }
        }

    private fun circle(fill: Int, strokeColor: Int? = null) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(fill)
        strokeColor?.let { setStroke(dp(1), it) }
    }

    private fun pill(fill: Int) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(12).toFloat()
        setColor(fill)
        setStroke(dp(1), 0xFF232326.toInt())
    }

    // -- state -------------------------------------------------------------

    fun setReady(isReady: Boolean) {
        ready = isReady
        if (!isReady) {
            status.text = context.getString(R.string.status_setup_needed)
        }
    }

    fun setState(recording: Boolean, transcribing: Boolean) {
        when {
            recording -> {
                micRing.background = circle(TEXT)
                micIcon.text = "■" // ■ stop
                micIcon.setTextColor(BG)
                status.text = context.getString(R.string.status_listening)
            }
            transcribing -> {
                micRing.background = circle(SURFACE, strokeColor = TEXT)
                micIcon.text = "…"
                micIcon.setTextColor(TEXT)
                status.text = context.getString(R.string.status_transcribing)
            }
            else -> {
                micRing.background = circle(SURFACE, strokeColor = 0xFF33333A.toInt())
                micIcon.text = "🎙"
                micIcon.setTextColor(TEXT)
                status.text = context.getString(
                    if (ready) R.string.status_idle else R.string.status_setup_needed
                )
            }
        }
    }

    /** Transient message on the status line (e.g. errors). */
    fun showStatus(text: String) {
        status.text = text
    }

    /** Breathes the mic ring with the input level while recording. */
    fun setLevel(level: Float) {
        val scale = 1f + (level.coerceIn(0f, 1f) * 0.18f)
        micRing.scaleX = scale
        micRing.scaleY = scale
    }
}
