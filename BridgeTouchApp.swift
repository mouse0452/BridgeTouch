import SwiftUI

@main
struct BridgeTouchApp: App {
    // 앱 전체에서 공유할 업데이트 체커 생성
    @StateObject var updateChecker = UpdateChecker()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                // ContentView가 이걸 쓸 수 있게 넘겨주기
                .environmentObject(updateChecker)
        }
        .commands {
            // ✨ 상단 메뉴바 > BridgeTouch > [Check for Updates...] 추가
            // 로컬라이징 키: "Check for Updates..."
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateChecker.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}
