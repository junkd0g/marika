import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun WelcomeScreen() {
    Column(Modifier.padding(40.dp).width(420.dp).background(Color.White, RoundedCornerShape(16.dp)).padding(32.dp)) {
        Text("Build complete", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Text("Artifacts are ready to review.", fontSize = 16.sp)
        Spacer(Modifier.height(24.dp))
        Button(onClick = {}, modifier = Modifier.width(356.dp).height(48.dp), shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(backgroundColor = Color(0xFF6254D9), contentColor = Color.White)) { Text("View artifacts") }
    }
}
