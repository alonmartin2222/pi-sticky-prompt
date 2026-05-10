import Foundation

/// Thin Unix-domain-socket client speaking the line-delimited JSON protocol
/// emitted by the pi-sticky-prompt pi extension.
final class BridgeClient {
    struct State {
        var streaming: Bool = false
        var model: String?
        var sessionName: String?
    }

    private let queue = DispatchQueue(label: "pi.bridge.io")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var rxBuffer = Data()

    var onState: ((State) -> Void)?
    var onHello: ((State) -> Void)?
    var onAck: ((_ ok: Bool, _ command: String, _ error: String?) -> Void)?
    var onClose: (() -> Void)?

    private(set) var state = State()
    private(set) var connectedSocket: String?

    deinit { disconnect() }

    func connect(toSocket path: String) -> Bool {
        disconnect()

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { c in
                for (i, b) in pathBytes.enumerated() { c[i] = CChar(b) }
                c[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + pathBytes.count)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, len)
            }
        }
        if rc != 0 {
            close(s); return false
        }
        fd = s
        connectedSocket = path
        startReading()
        return true
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        connectedSocket = nil
        rxBuffer.removeAll(keepingCapacity: false)
    }

    var isConnected: Bool { fd >= 0 }

    func sendPrompt(_ text: String) {
        send(["type": "prompt", "text": text])
    }
    func sendAbort() {
        send(["type": "abort"])
    }
    func sendPing() {
        send(["type": "ping"])
    }

    private func send(_ obj: [String: Any]) {
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else {
            return
        }
        let payload = data + Data([0x0a])
        queue.async { [fd] in
            payload.withUnsafeBytes { raw in
                var sent = 0
                let total = payload.count
                let base = raw.baseAddress!
                while sent < total {
                    let n = write(fd, base.advanced(by: sent), total - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = src
        src.setEventHandler { [weak self] in
            guard let self = self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.fd, &buf, buf.count)
            if n <= 0 {
                self.handleClose()
                return
            }
            self.rxBuffer.append(buf, count: n)
            self.drainLines()
        }
        src.setCancelHandler {}
        src.resume()
    }

    private func handleClose() {
        disconnect()
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    private func drainLines() {
        while let nl = rxBuffer.firstIndex(of: 0x0a) {
            let lineData = rxBuffer.subdata(in: 0..<nl)
            rxBuffer.removeSubrange(0...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else {
                continue
            }
            switch type {
            case "hello":
                state.streaming   = (obj["streaming"]   as? Bool) ?? false
                state.model       =  obj["model"]       as? String
                state.sessionName =  obj["sessionName"] as? String
                let s = state
                DispatchQueue.main.async { [weak self] in self?.onHello?(s) }
            case "state":
                state.streaming   = (obj["streaming"]   as? Bool) ?? state.streaming
                state.model       = (obj["model"]       as? String) ?? state.model
                state.sessionName = (obj["sessionName"] as? String) ?? state.sessionName
                let s = state
                DispatchQueue.main.async { [weak self] in self?.onState?(s) }
            case "ack":
                let ok      = (obj["ok"] as? Bool) ?? false
                let command = (obj["command"] as? String) ?? "?"
                let error   =  obj["error"] as? String
                DispatchQueue.main.async { [weak self] in self?.onAck?(ok, command, error) }
            case "bye":
                handleClose()
                return
            default:
                continue
            }
        }
    }
}
