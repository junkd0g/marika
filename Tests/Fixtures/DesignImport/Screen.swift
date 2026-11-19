import SwiftUI
struct WelcomeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome back").font(.system(size: 28, weight: .bold))
            Text("Your workspace is ready.").padding(.bottom, 8)
            Button("Continue") {}.font(.system(size: 16, weight: .semibold))
                .frame(width: 356, height: 48).foregroundStyle(.white)
                .background(Color(red: 98/255, green: 84/255, blue: 217/255), in: RoundedRectangle(cornerRadius: 12))
        }.padding(32).frame(width: 420).background(.white, in: RoundedRectangle(cornerRadius: 16)).padding(40)
    }
}
