package io.github.avejapl.voiceflow

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.provider.Settings.ACTION_INPUT_METHOD_SETTINGS
import android.view.Gravity
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import io.github.avejapl.voiceflow.model.ModelManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val BG = 0xFF0A0A0B.toInt()
private const val SURFACE = 0xFF131315.toInt()
private const val TEXT = 0xFFF5F5F7.toInt()
private const val MUTED = 0xFF9A9AA2.toInt()

/**
 * Setup and settings in one screen: enable the keyboard, grant the mic,
 * download a model, pick language and vocabulary. Deliberately a single
 * scrolling page — this app is a keyboard, not a destination.
 */
class MainActivity : ComponentActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var settings: Settings

    private lateinit var stepKeyboard: TextView
    private lateinit var stepMic: TextView
    private lateinit var stepModel: TextView
    private lateinit var progress: ProgressBar
    private lateinit var progressLabel: TextView

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BG)
            setPadding(dp(24), dp(40), dp(24), dp(40))
        }

        root.addView(TextView(this).apply {
            text = getString(R.string.app_name)
            setTextColor(TEXT)
            textSize = 30f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = -0.03f
        })
        root.addView(TextView(this).apply {
            text = getString(R.string.setup_tagline)
            setTextColor(MUTED)
            textSize = 15f
        }, lp(topMargin = dp(6)))

        // -- step 1: enable keyboard --------------------------------------
        stepKeyboard = stepLabel(root)
        root.addView(button(getString(R.string.setup_enable_keyboard)) {
            startActivity(Intent(ACTION_INPUT_METHOD_SETTINGS))
        })
        root.addView(button(getString(R.string.setup_pick_keyboard)) {
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .showInputMethodPicker()
        })

        // -- step 2: microphone -------------------------------------------
        stepMic = stepLabel(root)
        root.addView(button(getString(R.string.setup_grant_mic)) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        })

        // -- step 3: model -------------------------------------------------
        stepModel = stepLabel(root)
        val group = RadioGroup(this)
        ModelManager.MODELS.forEach { spec ->
            group.addView(RadioButton(this).apply {
                text = getString(
                    R.string.setup_model_entry, spec.id, spec.sizeMb, spec.description
                )
                setTextColor(TEXT)
                tag = spec.id
                isChecked = spec.id == settings.modelId
                setOnClickListener {
                    settings.modelId = spec.id
                    refresh()
                }
            })
        }
        root.addView(group, lp(topMargin = dp(4)))
        root.addView(button(getString(R.string.setup_download_model)) { downloadModel() })
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            visibility = android.view.View.GONE
        }
        root.addView(progress, lp(topMargin = dp(8)))
        progressLabel = TextView(this).apply {
            setTextColor(MUTED)
            textSize = 13f
        }
        root.addView(progressLabel)

        // -- language + vocabulary ----------------------------------------
        root.addView(sectionLabel(getString(R.string.setup_language)))
        val language = field(settings.language, hint = "pl / en / de / auto")
        root.addView(language)

        root.addView(sectionLabel(getString(R.string.setup_vocabulary)))
        val vocabulary = field(settings.vocabulary, hint = getString(R.string.setup_vocabulary_hint))
        vocabulary.minLines = 3
        vocabulary.isSingleLine = false
        root.addView(vocabulary)

        root.addView(button(getString(R.string.setup_save)) {
            settings.language = language.text.toString().trim().ifBlank { "auto" }
            settings.vocabulary = vocabulary.text.toString()
            Toast.makeText(this, getString(R.string.setup_saved), Toast.LENGTH_SHORT).show()
        })

        setContentView(ScrollView(this).apply {
            setBackgroundColor(BG)
            addView(root)
        })
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    // -- helpers -----------------------------------------------------------

    private fun refresh() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val enabled = imm.enabledInputMethodList.any { it.packageName == packageName }
        val mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        val spec = ModelManager.spec(settings.modelId)
        val model = ModelManager.isDownloaded(this, spec)

        stepKeyboard.text = stepText(1, getString(R.string.setup_step_keyboard), enabled)
        stepMic.text = stepText(2, getString(R.string.setup_step_mic), mic)
        stepModel.text = stepText(3, getString(R.string.setup_step_model, spec.id), model)
    }

    private fun stepText(n: Int, label: String, done: Boolean): String =
        "${if (done) "✅" else "⬜"}  $n. $label"

    private fun downloadModel() {
        val spec = ModelManager.spec(settings.modelId)
        if (ModelManager.isDownloaded(this, spec)) {
            refresh(); return
        }
        progress.visibility = android.view.View.VISIBLE
        progressLabel.text = getString(R.string.setup_downloading, spec.fileName, spec.sizeMb)
        scope.launch {
            try {
                ModelManager.download(this@MainActivity, spec) { fraction ->
                    scope.launch { progress.progress = (fraction * 100).toInt() }
                }
                withContext(Dispatchers.Main) {
                    progressLabel.text = getString(R.string.setup_download_done)
                    refresh()
                }
            } catch (e: Exception) {
                progressLabel.text = getString(R.string.setup_download_failed, e.message ?: "?")
            }
        }
    }

    private fun stepLabel(parent: LinearLayout): TextView =
        TextView(this).apply {
            setTextColor(TEXT)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
        }.also { parent.addView(it, lp(topMargin = dp(28))) }

    private fun sectionLabel(text: String): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(TEXT)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
        }.apply { layoutParams = lp(topMargin = dp(28)) }

    private fun button(label: String, onTap: () -> Unit): Button =
        Button(this).apply {
            text = label
            isAllCaps = false
            setTextColor(BG)
            setBackgroundColor(TEXT)
            setOnClickListener { onTap() }
            layoutParams = lp(topMargin = dp(8))
        }

    private fun field(value: String, hint: String): EditText =
        EditText(this).apply {
            setText(value)
            this.hint = hint
            setTextColor(TEXT)
            setHintTextColor(0xFF55555C.toInt())
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(SURFACE)
                setStroke(dp(1), 0xFF232326.toInt())
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layoutParams = lp(topMargin = dp(8))
        }

    private fun lp(topMargin: Int = 0): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { this.topMargin = topMargin }
}
