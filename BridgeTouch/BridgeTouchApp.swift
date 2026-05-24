import SwiftUI
import AppKit

@main
struct BridgeTouchApp: App {
    // 앱 전체에서 공유할 서버 및 업데이트 체커 생성
    @StateObject var server = BridgeServer()
    @StateObject var updateChecker = UpdateChecker()
    
    @AppStorage("showMenuBarIcon") var showMenuBarIcon: Bool = true
    
    @Environment(\.openWindow) private var openWindow
    
    init() {
        // 앱 실행 시 응용 프로그램 폴더로 이동 확인
        AppMigrator.migrate()
    }
    
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                // ContentView 및 하위 뷰가 사용할 수 있게 환경 객체 넘겨주기
                .environmentObject(server)
                .environmentObject(updateChecker)
        }
        .commands {
            // ✨ 상단 메뉴바 > BridgeTouch > [Check for Updates...] 추가
            // 로컬라이징 키: "Check for Updates..."
            CommandGroup(after: .appInfo) {
                Button {
                    updateChecker.checkForUpdates(isManual: true)
                } label: {
                    Label("Check for Updates...", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }
        
        MenuBarExtra("BridgeTouch", systemImage: "cursorarrow", isInserted: $showMenuBarIcon) {
            Button(String(localized: "Open BridgeTouch")) {
                // 창 열 때 앱을 활성화해서 맨 앞으로 가져오기
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            
            Divider()
            
            // 서버 상태 표시
            Text(String(format: String(localized: "Status: %@"), server.serverLog))
            
            if server.isReady {
                let urlString = "http://\(server.ipAddress):\(server.serverPort)"
                Text(urlString)
                
                Button(String(localized: "Copy Link")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(urlString, forType: .string)
                }
                
                Button(String(localized: "Stop Server")) {
                    server.stop()
                }
            } else {
                Button(String(localized: "Start Server")) {
                    server.start()
                }
            }
            
            Divider()
            
            Button(String(localized: "Check for Updates...")) {
                updateChecker.checkForUpdates(isManual: true)
            }
            
            Divider()
            
            Button(String(localized: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
