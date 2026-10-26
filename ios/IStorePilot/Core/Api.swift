import Foundation

struct ApiError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

/// 内存快照：切页签时先把上次的数据画出来，界面不会白一下。
/// 落盘没必要 —— 冷启动本来就要等一次网络。
final class SnapCache {
    static let shared = SnapCache()
    private var map: [String: J] = [:]
    private let lock = NSLock()

    func get(_ k: String) -> J? {
        lock.lock(); defer { lock.unlock() }
        return map[k]
    }

    func put(_ k: String, _ v: J) {
        lock.lock(); defer { lock.unlock() }
        map[k] = v
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}

enum Api {

    /// 令牌失效时统一回到登录页
    static var onAuthFail: (() -> Void)?

    static func cached(_ path: String) -> J? { SnapCache.shared.get(path) }

    static func get(_ path: String, cache: Bool = true) async throws -> J {
        let j = try await exec(base: Session.base, token: Session.token,
                               method: "GET", path: path, body: nil, timeout: 15)
        if cache { SnapCache.shared.put(path, j) }
        return j
    }

    static func post(_ path: String, _ body: J? = nil, slow: Bool = false) async throws -> J {
        try await exec(base: Session.base, token: Session.token,
                       method: "POST", path: path, body: body,
                       timeout: slow ? 180 : 20)
    }

    static func login(base: String, password: String) async throws -> J {
        try await exec(base: Session.normalize(base), token: "",
                       method: "POST", path: "/api/v1/login",
                       body: ["password": password], timeout: 12)
    }

    /// 探活，不需要令牌
    static func ping(base: String) async throws -> J {
        try await exec(base: Session.normalize(base), token: "",
                       method: "GET", path: "/api/v1/ping", body: nil, timeout: 6)
    }

    static func upload(data: Data, filename: String) async throws -> J {
        var req = URLRequest(url: URL(string: Session.base + "/api/v1/system/upload")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(Session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // 文件名放头里而不是 URL 里：.ipk / .run 的名字可能带空格和中文
        req.setValue(filename, forHTTPHeaderField: "X-Filename")

        let (data2, resp) = try await URLSession.shared.upload(for: req, from: data)
        return try decode(data2, resp as? HTTPURLResponse)
    }

    // MARK: - 底层

    private static func exec(base: String, token: String, method: String,
                             path: String, body: J?, timeout: TimeInterval) async throws -> J {
        guard let url = URL(string: base + path) else {
            throw ApiError(code: 0, message: "地址不合法")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let j = try decode(data, resp as? HTTPURLResponse)
            return j
        } catch let e as ApiError {
            if e.code == 401 {
                Session.logout()
                SnapCache.shared.clear()
                await MainActor.run { onAuthFail?() }
            }
            throw e
        } catch let e as URLError {
            throw ApiError(code: 0, message: friendly(e))
        }
    }

    private static func decode(_ data: Data, _ resp: HTTPURLResponse?) throws -> J {
        let code = resp?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""

        if code >= 400 {
            var msg = "请求失败（HTTP \(code)）"
            if let j = try? JSONSerialization.jsonObject(with: data) as? J {
                let m = j.str("error")
                if !m.isEmpty { msg = m }
            }
            throw ApiError(code: code, message: msg)
        }
        if text.isEmpty { return [:] }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? J else {
            throw ApiError(code: 0, message: "返回的不是有效数据，地址可能指错了地方")
        }
        return j
    }

    private static func friendly(_ e: URLError) -> String {
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "找不到这个地址，检查 IP 或域名是否写对"
        case .cannotConnectToHost:
            return "连不上路由器，确认手机和路由器在同一个局域网"
        case .timedOut:
            return "请求超时，路由器可能正忙"
        case .notConnectedToInternet:
            return "手机没有联网"
        case .networkConnectionLost:
            return "网络连接断了"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "HTTPS 证书有问题，试试换成 http://"
        default:
            return e.localizedDescription
        }
    }
}
