import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.MaterialTheme
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Density
import java.io.File

@OptIn(ExperimentalComposeUiApi::class)
fun main(args: Array<String>) {
    val scene = ImageComposeScene(width = 560, height = 380, density = Density(1f)) {
        MaterialTheme {
            Box(Modifier.fillMaxSize().background(Color(0xFFF4F4F8))) {
                WelcomeScreen()
            }
        }
    }
    try {
        scene.render().use { image ->
            image.encodeToData()!!.use { encoded ->
                File(args.single()).writeBytes(encoded.bytes)
            }
        }
    } finally {
        scene.close()
    }
}
