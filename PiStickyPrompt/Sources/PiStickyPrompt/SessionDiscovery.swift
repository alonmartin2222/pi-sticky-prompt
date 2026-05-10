import Foundation

struct PiSession: Hashable, Identifiable {
    let pid: Int32
    let cwd: String
    let socket: String
    let started: Double
    let sessionName: String?
    let model: String?
    let streaming: Bool

    var id: Int32 { pid }
    var label: String {
        let name = sessionName?.isEmpty == false ? sessionName! : (cwd as NSString).lastPathComponent
        return "\(name)  ·  pid \(pid)"
    }
}

enum SessionDiscovery {
    static var dir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pi/agent/sockets", isDirectory: true)
    }

    /// Scan the sockets dir, parse every pi-*.json descriptor, and drop
    /// stale ones whose PID is no longer alive.
    static func list() -> [PiSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil) else {
            return []
        }

        var out: [PiSession] = []
        for url in entries where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("pi-") {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let socket = obj["socket"] as? String,
                  let cwd = obj["cwd"] as? String else {
                continue
            }
            // kill(pid, 0) returns 0 if process exists; ESRCH otherwise.
            if kill(pid, 0) != 0 {
                try? fm.removeItem(at: url)
                let sock = url.deletingPathExtension().appendingPathExtension("sock")
                try? fm.removeItem(at: sock)
                continue
            }
            out.append(PiSession(
                pid: pid,
                cwd: cwd,
                socket: socket,
                started: (obj["started"] as? NSNumber)?.doubleValue ?? 0,
                sessionName: obj["sessionName"] as? String,
                model: obj["model"] as? String,
                streaming: (obj["streaming"] as? Bool) ?? false
            ))
        }
        return out.sorted { $0.started > $1.started }
    }
}
