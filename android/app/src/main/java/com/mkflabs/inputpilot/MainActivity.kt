package com.mkflabs.inputpilot

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.mkflabs.inputpilot.ui.InputPilotNav
import com.mkflabs.inputpilot.ui.theme.InputPilotTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            InputPilotTheme {
                InputPilotNav()
            }
        }
    }
}
