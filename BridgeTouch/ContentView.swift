import SwiftUI
import Network
import CoreGraphics
import Combine
import Foundation
import CoreImage

// MARK: - 0. 업데이트 확인 클래스
// (BridgeTouchApp에서도 써야 해서 클래스 정의를 여기에 둠)
class UpdateChecker: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var showUpdateAlert: Bool = false
    @Published var showNoUpdateAlert: Bool = false // 업데이트가 없을 때 알림 제어
    @Published var latestVersion: String = ""
    @Published var releaseURL: String = ""
    
    // 다운로드 관련 상태
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var showDownloadProgress: Bool = false
    @Published var showRelaunchAlert: Bool = false
    
    // 👇 진욱이 깃허브 정보
    let githubUser = "mouse0452"
    let repoName = "BridgeTouch"
    var assetDownloadURL: String = ""
    
    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()
    
    func startDownload() {
        guard let url = URL(string: assetDownloadURL) else {
            // URL이 없는 경우 깃허브 페이지를 웹으로 열기
            if let webURL = URL(string: releaseURL) {
                NSWorkspace.shared.open(webURL)
            }
            return
        }
        
        isDownloading = true
        downloadProgress = 0.0
        showDownloadProgress = true
        
        let task = downloadSession.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        showDownloadProgress = false
    }
    
    // MARK: - URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fileManager = FileManager.default
        let tempFileURL = fileManager.temporaryDirectory.appendingPathComponent(downloadTask.response?.suggestedFilename ?? "BridgeTouch-Update")
        
        try? fileManager.removeItem(at: tempFileURL)
        
        do {
            try fileManager.moveItem(at: location, to: tempFileURL)
            DispatchQueue.main.async {
                self.isDownloading = false
                self.showDownloadProgress = false
                // 자동 업데이트 설치 진행
                self.installUpdate(downloadedFileURL: tempFileURL)
            }
        } catch {
            print("❌ File Move Error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isDownloading = false
                self.showDownloadProgress = false
                // 오류 시 브라우저 열기로 폴백
                if let url = URL(string: self.releaseURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("❌ Download Error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isDownloading = false
                self.showDownloadProgress = false
                // 오류 시 브라우저 열기로 폴백
                if let url = URL(string: self.releaseURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    // 자동 업데이트 설치 및 재시작 로직
    func installUpdate(downloadedFileURL: URL) {
        let fileManager = FileManager.default
        
        // 1. 권한 확인 (앱 경로가 쓰기 가능한지)
        let currentAppURL = Bundle.main.bundleURL
        let parentDir = currentAppURL.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: parentDir.path) || 
           (fileManager.fileExists(atPath: currentAppURL.path) && !fileManager.isWritableFile(atPath: currentAppURL.path)) {
            print("⚠️ App directory is not writable. Falling back to manual install.")
            NSWorkspace.shared.open(downloadedFileURL)
            return
        }
        
        // 2. 임시 폴더 생성
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create temp directory: \(error.localizedDescription)")
            NSWorkspace.shared.open(downloadedFileURL)
            return
        }
        
        let pathExtension = downloadedFileURL.pathExtension.lowercased()
        let mountPoint = tempDir.appendingPathComponent("Mount")
        
        // 3. 압축 해제 또는 마운트
        if pathExtension == "zip" {
            let dittoProcess = Process()
            dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            dittoProcess.arguments = ["-x", "-k", downloadedFileURL.path, tempDir.path]
            do {
                try dittoProcess.run()
                dittoProcess.waitUntilExit()
            } catch {
                print("❌ Ditto extract failed: \(error.localizedDescription)")
                NSWorkspace.shared.open(downloadedFileURL)
                return
            }
        } else if pathExtension == "dmg" {
            try? fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true, attributes: nil)
            let hdiutilAttach = Process()
            hdiutilAttach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hdiutilAttach.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, downloadedFileURL.path]
            do {
                try hdiutilAttach.run()
                hdiutilAttach.waitUntilExit()
            } catch {
                print("❌ hdiutil attach failed: \(error.localizedDescription)")
                NSWorkspace.shared.open(downloadedFileURL)
                return
            }
        } else {
            // 알 수 없는 파일 형식인 경우 직접 파일 열기
            NSWorkspace.shared.open(downloadedFileURL)
            return
        }
        
        // 4. 새 앱 번들 찾기
        guard let newAppURL = findAppBundle(in: tempDir) else {
            print("❌ Could not find BridgeTouch.app in downloaded content.")
            detachDMG(at: mountPoint)
            NSWorkspace.shared.open(downloadedFileURL)
            return
        }
        
        // 5. 안전한 임시 위치로 새 앱 복사 (DMG 언마운트를 위해 필요)
        let safeTempNewAppURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("BridgeTouch.app")
        try? fileManager.createDirectory(at: safeTempNewAppURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        
        do {
            try fileManager.copyItem(at: newAppURL, to: safeTempNewAppURL)
        } catch {
            print("❌ Failed to copy to safe temp location: \(error.localizedDescription)")
            detachDMG(at: mountPoint)
            NSWorkspace.shared.open(downloadedFileURL)
            return
        }
        
        // 6. DMG 마운트 해제 및 임시 폴더 삭제
        detachDMG(at: mountPoint)
        try? fileManager.removeItem(at: tempDir)
        try? fileManager.removeItem(at: downloadedFileURL)
        
        // 7. 교체 작업을 즉시 진행 (실행 중인 앱은 메모리 상에서 계속 동작)
        
        do {
            try fileManager.removeItem(at: currentAppURL)
            try fileManager.moveItem(at: safeTempNewAppURL, to: currentAppURL)
            
            // 성공 시, 사용자에게 재시작 여부를 묻는 알림창 트리거
            DispatchQueue.main.async {
                self.showRelaunchAlert = true
            }
        } catch {
            print("❌ Failed to replace app binary: \(error.localizedDescription)")
            // 폴백으로 임시 위치의 새 앱 실행 시도
            NSWorkspace.shared.open(safeTempNewAppURL)
        }
    }
    
    // 앱 교체 후 재시작 진행
    func relaunchApp() {
        let currentAppPath = Bundle.main.bundleURL.path
        let currentPID = ProcessInfo.processInfo.processIdentifier
        
        let script = """
        (
            while kill -0 \(currentPID) 2>/dev/null; do
                sleep 0.1
            done
            open "\(currentAppPath)"
        ) &
        """
        
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        shellProcess.arguments = ["-c", script]
        
        do {
            try shellProcess.run()
            exit(0)
        } catch {
            print("❌ Relaunch script execution failed: \(error.localizedDescription)")
            exit(0)
        }
    }
    
    private func findAppBundle(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if directory.lastPathComponent == "BridgeTouch.app" {
            return directory
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "BridgeTouch.app" {
                return fileURL
            }
        }
        return nil
    }
    
    private func detachDMG(at mountPoint: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: mountPoint.path) {
            let hdiutilDetach = Process()
            hdiutilDetach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hdiutilDetach.arguments = ["detach", mountPoint.path]
            try? hdiutilDetach.run()
            hdiutilDetach.waitUntilExit()
        }
    }
    
    func checkForUpdates(isManual: Bool = false) {
        guard let url = URL(string: "https://api.github.com/repos/\(githubUser)/\(repoName)/releases/latest") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("BridgeTouch-App", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Update Check Connection Error: \(error.localizedDescription)")
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("🔍 Update Check Status: \(httpResponse.statusCode)")
            }
            
            guard let data = data, error == nil else {
                if isManual {
                    DispatchQueue.main.async {
                        self.showNoUpdateAlert = true
                    }
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    print("🔍 Update Check JSON: \(json)")
                    
                    if let tagName = json["tag_name"] as? String,
                       let htmlUrl = json["html_url"] as? String {
                        
                        let cleanLatest = tagName.replacingOccurrences(of: "v", with: "")
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                        
                        print("🔍 Current: \(currentVersion) / Latest: \(cleanLatest)")
                        
                        // 다운로드 링크 추출 (.dmg, .zip, .pkg 순으로 찾고 없으면 소스 코드 zip 폴백)
                        var downloadUrl = htmlUrl
                        if let assets = json["assets"] as? [[String: Any]] {
                            if let firstAsset = assets.first(where: { 
                                let name = ($0["name"] as? String ?? "").lowercased()
                                return name.hasSuffix(".dmg") || name.hasSuffix(".zip") || name.hasSuffix(".pkg")
                            }),
                            let assetUrl = firstAsset["browser_download_url"] as? String {
                                downloadUrl = assetUrl
                            } else if let zipballUrl = json["zipball_url"] as? String {
                                downloadUrl = zipballUrl
                            }
                        }
                        
                        DispatchQueue.main.async {
                            self.assetDownloadURL = downloadUrl
                            self.latestVersion = cleanLatest
                            self.releaseURL = htmlUrl
                            
                            if cleanLatest.compare(currentVersion, options: .numeric) == .orderedDescending {
                                self.showUpdateAlert = true
                            } else {
                                if isManual {
                                    self.showNoUpdateAlert = true
                                }
                            }
                        }
                    } else {
                        print("❌ Update Check: Invalid JSON keys. message: \(json["message"] ?? "")")
                        if isManual {
                            DispatchQueue.main.async {
                                self.showNoUpdateAlert = true
                            }
                        }
                    }
                }
            } catch {
                print("❌ Update Check JSON Error: \(error.localizedDescription)")
                if isManual {
                    DispatchQueue.main.async {
                        self.showNoUpdateAlert = true
                    }
                }
            }
        }.resume()
    }
}

// MARK: - 1. 마우스 조종 클래스
class MouseController {
    let source = CGEventSource(stateID: .combinedSessionState)
    var sensitivity: Double = 1.5
    var isNaturalScrolling: Bool = false
    var zoomAccumulator: CGFloat = 0
    
    func moveMouse(dx: CGFloat, dy: CGFloat, isDragging: Bool = false) {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let newPoint = CGPoint(x: currentPos.x + dx * CGFloat(sensitivity),
                               y: (screenHeight - currentPos.y) + dy * CGFloat(sensitivity))
        
        let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: newPoint, mouseButton: .left) {
            event.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
    
    func zoomMouse(magnification: CGFloat) {
        zoomAccumulator += (magnification * 50)
        let scrollAmount = Int32(zoomAccumulator)
        if scrollAmount == 0 { return }
        zoomAccumulator -= CGFloat(scrollAmount)
        
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: scrollAmount, wheel2: 0, wheel3: 0) else { return }
        event.flags.insert(.maskCommand)
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    func scrollMouse(dx: CGFloat, dy: CGFloat) {
        let direction: CGFloat = isNaturalScrolling ? 1 : -1
        let scrollEvent = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy * 2.5 * direction),
                                  wheel2: Int32(dx * 2.5 * direction),
                                  wheel3: 0)
        scrollEvent?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func clickMouse() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let clickPoint = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)
        
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left)
        
        mouseDown?.post(tap: CGEventTapLocation.cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            mouseUp?.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
    
    func doubleClickMouse() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let point = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)
        
        let down1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down1?.setIntegerValueField(.mouseEventClickState, value: 1)
        up1?.setIntegerValueField(.mouseEventClickState, value: 1)
        down1?.post(tap: CGEventTapLocation.cghidEventTap)
        up1?.post(tap: CGEventTapLocation.cghidEventTap)
        
        let down2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down2?.setIntegerValueField(.mouseEventClickState, value: 2)
        up2?.setIntegerValueField(.mouseEventClickState, value: 2)
        down2?.post(tap: CGEventTapLocation.cghidEventTap)
        up2?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func rightClickMouse() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let clickPoint = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)
        
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: clickPoint, mouseButton: .right)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: clickPoint, mouseButton: .right)
        
        mouseDown?.post(tap: CGEventTapLocation.cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            mouseUp?.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
    
    func dragStart() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let clickPoint = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left)
        event?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func dragEnd() {
        let currentPos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let clickPoint = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left)
        event?.post(tap: CGEventTapLocation.cghidEventTap)
    }
}

// MARK: - 2. 통합 서버 클래스
class BridgeServer: ObservableObject {
    @Published var serverLog: String = ""
    @Published var ipAddress: String = ""
    @Published var isReady: Bool = false
    
    @AppStorage("sensitivity") var sensitivity: Double = 1.5 {
        didSet { mouseController.sensitivity = sensitivity }
    }
    @AppStorage("isNaturalScrolling") var isNaturalScrolling: Bool = false {
        didSet { mouseController.isNaturalScrolling = isNaturalScrolling }
    }
    
    var listener: NWListener?
    var activeConnections: [NWConnection] = []
    let mouseController = MouseController()
    
    init() {
        mouseController.sensitivity = sensitivity
        mouseController.isNaturalScrolling = isNaturalScrolling
        // 로컬라이징 키 적용 (Waiting..., Checking IP...)
        self.serverLog = String(localized: "Waiting...")
        self.ipAddress = String(localized: "Checking IP...")
    }
    
    func start() {
        do {
            listener = try NWListener(using: .tcp, on: .init(integerLiteral: 8080))
            listener?.newConnectionHandler = { connection in
                connection.start(queue: .main)
                self.activeConnections.append(connection)
                self.handleConnection(connection)
            }
            listener?.start(queue: .main)
            self.serverLog = String(localized: "✅ Ready")
            self.isReady = true
            self.ipAddress = self.getIPAddress() ?? String(localized: "Unknown IP")
        } catch {
            self.serverLog = String(format: String(localized: "❌ Error: %@"), error.localizedDescription)
            self.isReady = false
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        for connection in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        self.serverLog = String(localized: "Waiting...")
        self.isReady = false
        self.ipAddress = String(localized: "Checking IP...")
    }
    
    func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed(_):
                DispatchQueue.main.async {
                    self.activeConnections.removeAll { $0 === connection }
                }
            default:
                break
            }
        }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, isComplete, error in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                let components = request.components(separatedBy: " ")
                guard components.count > 1 else { return }
                let url = components[1]
                
                if request.contains("GET / ") { self.sendHTML(to: connection) }
                else {
                    DispatchQueue.main.async {
                        if url.contains("/move?") { self.parseAndMove(url, isDragging: false) }
                        else if url.contains("/drag-move?") { self.parseAndMove(url, isDragging: true) }
                        else if url.contains("/drag-start") { self.mouseController.dragStart() }
                        else if url.contains("/drag-end") { self.mouseController.dragEnd() }
                        else if url.contains("/scroll?") { self.parseAndScroll(url) }
                        else if url.contains("/zoom?") { self.parseAndZoom(url) }
                        else if url.contains("/click") { self.mouseController.clickMouse() }
                        else if url.contains("/double-click") { self.mouseController.doubleClickMouse() }
                        else if url.contains("/right-click") { self.mouseController.rightClickMouse() }
                    }
                }
                if !request.contains("GET / ") { self.sendResponse(to: connection) }
            }
            if isComplete {
                connection.cancel()
            }
            else if error == nil {
                self.handleConnection(connection)
            } else {
                connection.cancel()
            }
        }
    }
    
    func parseAndMove(_ url: String, isDragging: Bool) {
        if let queryItems = URLComponents(string: url)?.queryItems {
            let dx = CGFloat(Double(queryItems.first(where: { $0.name == "x" })?.value ?? "0") ?? 0)
            let dy = CGFloat(Double(queryItems.first(where: { $0.name == "y" })?.value ?? "0") ?? 0)
            self.mouseController.moveMouse(dx: dx, dy: dy, isDragging: isDragging)
        }
    }
    
    func parseAndScroll(_ url: String) {
        if let queryItems = URLComponents(string: url)?.queryItems {
            let dx = CGFloat(Double(queryItems.first(where: { $0.name == "dx" })?.value ?? "0") ?? 0)
            let dy = CGFloat(Double(queryItems.first(where: { $0.name == "dy" })?.value ?? "0") ?? 0)
            self.mouseController.scrollMouse(dx: dx, dy: dy)
        }
    }
    
    func parseAndZoom(_ url: String) {
        if let queryItems = URLComponents(string: url)?.queryItems {
            let mag = CGFloat(Double(queryItems.first(where: { $0.name == "mag" })?.value ?? "0") ?? 0)
            self.mouseController.zoomMouse(magnification: mag)
        }
    }

    func sendHTML(to connection: NWConnection) {
        let body = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            body{background:#000;color:white;margin:0;overflow:hidden;touch-action:none;height:100vh;width:100vw;display:flex;align-items:center;justify-content:center;user-select:none;-webkit-user-select:none;font-family: -apple-system;}
            #status { position: absolute; top: 20px; color: #888; font-size: 14px; font-weight: 600; pointer-events: none; }
            #pad{width:100%;height:100%;}
        </style></head>
        <body>
            <div id="status">Connected</div>
            <div id="pad"></div>
            <script>
            const statusEl = document.getElementById('status');
            const p = document.getElementById('pad');
            
            let lx=0, ly=0, moved=false, touchCount=0, lastTap=0, isDragging=false;
            let startDist=0, lastDist=0, startX=0, startY=0, lastX=0, lastY=0;
            let gestureMode = null; 
            
            let accX=0, accY=0, isSending=false; 
            let dragDistX=0, dragDistY=0;
            let isPotentialDrag = false;
            
            function updateStatus(text, color="#888") {
                statusEl.innerText = text;
                statusEl.style.color = color;
            }
            
            function getDistance(e) {
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                return Math.hypot(dx, dy);
            }
            
            function sendMoveData(route) {
                if (isSending || (accX === 0 && accY === 0)) return;
                isSending = true;
                const sendX = accX; const sendY = accY;
                accX = 0; accY = 0;
                fetch(`${route}?x=${sendX}&y=${sendY}`)
                    .then(() => {
                        isSending = false;
                        if (accX !== 0 || accY !== 0) sendMoveData(route);
                    })
                    .catch(() => isSending = false);
            }

            function resetCoords(e) {
                touchCount = e.touches.length;
                if (touchCount === 1) { 
                    lx = e.touches[0].clientX; ly = e.touches[0].clientY; 
                    updateStatus("Ready");
                } else if (touchCount === 2) { 
                    lx = (e.touches[0].clientX + e.touches[1].clientX) / 2; 
                    ly = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                    startDist = getDistance(e);
                    lastDist = startDist;
                    startX = lx; startY = ly;
                    lastX = lx; lastY = ly;
                    gestureMode = null; 
                    updateStatus("Detecting Gesture...");
                }
            }

            p.addEventListener('touchstart',e=>{
                const now = Date.now();
                if (now - lastTap < 200 && e.touches.length === 1) {
                    isPotentialDrag = true;
                    updateStatus("Checking...", "#0a84ff");
                    dragDistX = 0; dragDistY = 0; 
                } else {
                    isPotentialDrag = false;
                }
                lastTap = now;
                resetCoords(e);
                moved=false;
                accX = 0; accY = 0;
            },{passive:false});
            
            p.addEventListener('touchmove',e=>{
                e.preventDefault();
                if (e.touches.length !== touchCount) { resetCoords(e); return; }
                
                if (touchCount === 1) {
                    const dx = e.touches[0].clientX - lx; const dy = e.touches[0].clientY - ly;
                    lx = e.touches[0].clientX; ly = e.touches[0].clientY;
                    if(Math.abs(dx)>0.5 || Math.abs(dy)>0.5) moved=true;
                    
                    if (isPotentialDrag) {
                        dragDistX += Math.abs(dx);
                        dragDistY += Math.abs(dy);
                        if (dragDistX < 3 && dragDistY < 3) return; 
                        
                        fetch('/drag-start');
                        isPotentialDrag = false; 
                        isDragging = true;
                        updateStatus("Dragging", "#0a84ff");
                    }
                    
                    accX += dx; accY += dy;
                    const route = (isDragging || document.getElementById('status').innerText.includes("Dragging")) ? '/drag-move' : '/move';
                    sendMoveData(route);
                    
                } else if (touchCount === 2) {
                    const currDist = getDistance(e);
                    const currentX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                    const currentY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                    
                    if (gestureMode === null) {
                        const distChange = Math.abs(currDist - startDist);
                        const xChange = Math.abs(currentX - startX);
                        const yChange = Math.abs(currentY - startY);
                        
                        if (distChange > 10 || yChange > 10 || xChange > 10) {
                            if (distChange > (xChange + yChange) * 1.5) { 
                                gestureMode = 'zoom';
                                updateStatus("Zooming", "#30d158");
                                lastDist = currDist; 
                            } else { 
                                gestureMode = 'scroll';
                                updateStatus("Scrolling", "#ff9f0a");
                                lastX = currentX;
                                lastY = currentY; 
                            }
                        }
                    }
                    
                    if (gestureMode === 'zoom') {
                        const delta = (currDist - lastDist) * 0.05;
                        fetch(`/zoom?mag=${delta}`);
                        lastDist = currDist;
                    } else if (gestureMode === 'scroll') {
                        const dx = currentX - lastX;
                        const dy = currentY - lastY; 
                        lastX = currentX;
                        lastY = currentY; 
                        moved = true;
                        fetch(`/scroll?dx=${dx}&dy=${dy}`);
                    }
                }
            },{passive:false});
            
            p.addEventListener('touchend',e=>{
                if (isPotentialDrag) {
                    fetch('/double-click'); 
                    updateStatus("Double Click!", "#ff3b30");
                    isPotentialDrag = false;
                } else if (isDragging) {
                    if (accX !== 0 || accY !== 0) fetch(`/drag-move?x=${accX}&y=${accY}`);
                    setTimeout(() => fetch('/drag-end'), 50);
                    isDragging = false; 
                } else if(!moved && gestureMode === null) {
                    if(touchCount === 1 && e.touches.length === 0) fetch('/click');
                    else if(touchCount === 2 && e.touches.length === 0) fetch('/right-click');
                }
                
                resetCoords(e);
                if (e.touches.length < 2) gestureMode = null;
                accX = 0; accY = 0;
            },{passive:false});
            
            p.addEventListener('touchcancel', e => {
                resetCoords(e); gestureMode = null; isDragging = false; isPotentialDrag = false;
            });
            </script></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    func sendResponse(to connection: NWConnection) {
        let res = "HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: res.data(using: .utf8), completion: .idempotent)
    }

    func getIPAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let sa = ptr!.pointee.ifa_addr.pointee
                if sa.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ptr!.pointee.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, socklen_t(0), NI_NUMERICHOST)
                    addr = String(cString: host)
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return addr
    }
}

// MARK: - 3. 설정 화면
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var updateChecker: UpdateChecker
    @Binding var sensitivity: Double
    @Binding var isNaturalScrolling: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Mouse Settings")) { // "Mouse Settings"
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: "cursorarrow.motionlines").foregroundStyle(.secondary)
                            Text("Sensitivity") // "Sensitivity"
                            Spacer()
                            Text(String(format: "%.1f", sensitivity)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $sensitivity, in: 0.5...3.0)
                    }
                    Toggle(isOn: $isNaturalScrolling) {
                        HStack {
                            Image(systemName: "arrow.up.arrow.down").foregroundStyle(.secondary)
                            Text("Natural Scrolling") // "Natural Scrolling"
                        }
                    }
                }
                
                Section {
                    Button {
                        updateChecker.checkForUpdates(isManual: true)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                            Text("Check for Updates...")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Settings")) // "Settings"
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } } // "Done"
        }
        .frame(width: 350, height: 260)
    }
}

// MARK: - 4. 메인 화면
struct ContentView: View {
    @StateObject var server = BridgeServer()
    
    // BridgeTouchApp에서 만든 걸 받아서 씁니다
    @EnvironmentObject var updateChecker: UpdateChecker
    
    @State private var showSettings = false
    
    // QR 코드 생성 함수 (CoreImage 사용)
    private func generateQRCode(from string: String) -> NSImage? {
        let data = string.data(using: String.Encoding.ascii)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            
            if let outputImage = filter.outputImage {
                // QR 코드를 선명하게 확대하기 위한 변환 (Nearest Neighbor 변환 효과 적용)
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledImage = outputImage.transformed(by: transform)
                
                let rep = NSCIImageRep(ciImage: scaledImage)
                let nsImage = NSImage(size: rep.size)
                nsImage.addRepresentation(rep)
                return nsImage
            }
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()
                
                VStack(spacing: 30) {
                    Spacer()
                    VStack(spacing: 15) {
                        Image(systemName: "bridge")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue.gradient)
                            .symbolEffect(.bounce, value: server.isReady)
                        
                        // "BridgeTouch"
                        Text(String(localized: "BridgeTouch"))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: server.isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(server.isReady ? .green : .red)
                            Text(server.serverLog).font(.headline)
                            Spacer()
                        }.padding().background(Color(NSColor.controlBackgroundColor))
                        Divider()
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            Text("http://\(server.ipAddress):8080")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                        }.padding().background(Color(NSColor.controlBackgroundColor))
                        
                        if server.isReady, let qrImage = generateQRCode(from: "http://\(server.ipAddress):8080") {
                            Divider()
                            VStack(spacing: 8) {
                                Image(nsImage: qrImage)
                                    .interpolation(.none) // QR 코드 이미지가 흐려지지 않게 처리
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 140, height: 140)
                                    .padding(8)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.1), radius: 3)
                                
                                Text(String(localized: "Scan to connect"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                    .padding(.horizontal)
                    
                    if server.isReady {
                        HStack(spacing: 16) {
                            Button { server.start() } label: {
                                Text(String(localized: "Restart Server"))
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            
                            Button { server.stop() } label: {
                                Text(String(localized: "Stop Server"))
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .controlSize(.large)
                        }
                        .padding(.horizontal, 20)
                    } else {
                        Button { server.start() } label: {
                            Text(String(localized: "Start Server"))
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 40)
                    }
                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(sensitivity: $server.sensitivity, isNaturalScrolling: $server.isNaturalScrolling)
                    .environmentObject(updateChecker)
            }
            .sheet(isPresented: $updateChecker.showDownloadProgress) {
                DownloadProgressView(progress: updateChecker.downloadProgress) {
                    updateChecker.cancelDownload()
                }
            }
            .onChange(of: updateChecker.showUpdateAlert) { _, show in
                if show {
                    showSettings = false
                }
            }
            .onChange(of: updateChecker.showNoUpdateAlert) { _, show in
                if show {
                    showSettings = false
                }
            }
            .onChange(of: updateChecker.showRelaunchAlert) { _, show in
                if show {
                    showSettings = false
                }
            }
            .onAppear {
                // 앱 켜지면 자동 업데이트 확인
                updateChecker.checkForUpdates()
            }
            // ✨ 에러 났던 부분 수정 완료!
            // 로컬라이징 키: "New Version Released 🚀"
            .alert(String(localized: "New Version Released 🚀"), isPresented: $updateChecker.showUpdateAlert) {
                Button(String(localized: "Download")) { // "Download"
                    updateChecker.startDownload()
                }
                Button(String(localized: "Later"), role: .cancel) { } // "Later" (덜 밀어주는 취소 역할)
            } message: {
                // 🔥 여기서 에러났던 걸 NSLocalizedString으로 교체!
                // 로컬라이징 키: "Update_Message %@"
                let message = String(format: NSLocalizedString("Update_Message %@", comment: ""), updateChecker.latestVersion)
                Text(message)
            }
            .alert(String(localized: "You're Up to Date"), isPresented: $updateChecker.showNoUpdateAlert) {
                Button(String(localized: "OK")) { }
            } message: {
                Text(String(localized: "No_Update_Message"))
            }
            .alert(String(localized: "Update Ready"), isPresented: $updateChecker.showRelaunchAlert) {
                Button(String(localized: "Restart")) { // "Restart" (기본 파란색 버튼)
                    updateChecker.relaunchApp()
                }
                Button(String(localized: "Later"), role: .cancel) { } // "Later" (덜 밀어주는 취소 역할)
            } message: {
                Text(String(localized: "Relaunch_Message"))
            }
        }
        .frame(width: 400, height: 580)
    }
}

// MARK: - 5. 다운로드 프로그레스 화면
struct DownloadProgressView: View {
    let progress: Double
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue.gradient)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Downloading Update..."))
                        .font(.headline)
                    Text(String(format: String(localized: "Progress: %.0f%%"), progress * 100))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
            
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 320, height: 140)
    }
}
