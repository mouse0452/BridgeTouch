import Cocoa

struct AppMigrator {
    static func migrate() {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        
        // 1. 이미 Applications 폴더에 있는지 확인 (/Applications 또는 ~/Applications)
        let systemAppsURL = URL(fileURLWithPath: "/Applications")
        let userAppsURL = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
        
        let isInSystemApps = bundleURL.path.hasPrefix(systemAppsURL.path)
        let isInUserApps = userAppsURL != nil && bundleURL.path.hasPrefix(userAppsURL!.path)
        
        // 이미 적절한 경로에 들어있으면 스킵
        if isInSystemApps || isInUserApps {
            return
        }
        
        // 디버그 빌드 및 개발 테스트 환경인 경우 스킵
        if bundleURL.path.contains("/DerivedData/") || 
           bundleURL.path.contains("/Build/") || 
           bundleURL.path.contains("/Xcode/") {
            return
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Move_To_Applications_Title", comment: "")
            alert.informativeText = NSLocalizedString("Move_To_Applications_Message", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Move_Button", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Quit_Button", comment: ""))
            
            // 앱이 활성 상태로 다이얼로그를 포커스하도록 유도
            NSApp.activate(ignoringOtherApps: true)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { // "이동" 선택
                let targetURL = systemAppsURL.appendingPathComponent(bundleURL.lastPathComponent)
                
                do {
                    // 동일 이름의 기존 앱이 타겟 폴더에 있다면 안전하게 삭제 후 이동
                    if fileManager.fileExists(atPath: targetURL.path) {
                        try fileManager.removeItem(at: targetURL)
                    }
                    
                    // 앱 복사
                    try fileManager.copyItem(at: bundleURL, to: targetURL)
                    
                    // 응용 프로그램 폴더로 복사된 새 앱 실행
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = [targetURL.path]
                    try process.run()
                    
                    // 구 위치의 앱을 휴지통으로 이동
                    try? fileManager.trashItem(at: bundleURL, resultingItemURL: nil)
                    
                    // 기존 프로세스 안전하게 종료
                    exit(0)
                } catch {
                    print("❌ App migration failed: \(error.localizedDescription)")
                    let errorAlert = NSAlert()
                    errorAlert.messageText = NSLocalizedString("Migration_Failed_Title", comment: "")
                    let formatString = NSLocalizedString("Migration_Failed_Message %@", comment: "")
                    errorAlert.informativeText = String(format: formatString, error.localizedDescription)
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                    exit(0)
                }
            } else {
                exit(0)
            }
        }
    }
}
