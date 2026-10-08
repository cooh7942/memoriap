import Foundation

/// 응답이 없을 수 있는 파일 시스템 호출(끊긴 네트워크 드라이브 등)을 타임아웃과 함께 실행.
///
/// 연결이 끊긴 SMB/AFP 마운트에서는 `fileExists`·`contentsOfDirectory` 같은 호출이
/// 수십 초~수 분간 반환되지 않는다. 메인 스레드에서 호출하면 앱 전체가 멈추고,
/// 백그라운드에서 호출해도 결과를 기다리는 동안 로딩 표시가 끝나지 않는다.
/// 여기서는 작업을 별도 스레드에서 돌리고, 시간이 넘으면 기다리지 않고 nil을 반환한다.
/// (멈춘 스레드 자체는 취소할 수 없으므로 늦게 끝난 결과는 `onLateResult`로 정리한다.)
enum FileProbe {

    nonisolated static let defaultTimeout: TimeInterval = 3

    nonisolated static func run<T: Sendable>(
        timeout: TimeInterval = defaultTimeout,
        _ operation: @escaping @Sendable () -> T,
        onLateResult: (@Sendable (T) -> Void)? = nil
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeGate()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = operation()
                if gate.claim() {
                    continuation.resume(returning: result)
                } else {
                    onLateResult?(result)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 경로가 접근 가능한 디렉터리인지 확인. 시간 초과 시 false.
    nonisolated static func isReachableDirectory(_ url: URL, timeout: TimeInterval = defaultTimeout) async -> Bool {
        let path = url.path
        return await run(timeout: timeout) {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        } ?? false
    }
}

/// continuation을 정확히 한 번만 resume하기 위한 플래그.
nonisolated private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
