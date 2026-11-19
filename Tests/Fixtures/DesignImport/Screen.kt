@Composable
fun WelcomeScreen() {
    Column(Modifier.padding(40.dp).width(420.dp).background(Color.White, RoundedCornerShape(16.dp)).padding(32.dp)) {
        Text("Welcome back", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Text("Your workspace is ready.", fontSize = 16.sp)
        Spacer(Modifier.height(24.dp))
        Button(onClick = {}, modifier = Modifier.width(356.dp).height(48.dp), shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6254D9))) { Text("Continue") }
    }
}
