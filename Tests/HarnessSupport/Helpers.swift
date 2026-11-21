import Foundation

// What every check in the harness uses. Kept out of harness.swift (which becomes main.swift) so
// that the area files beside this one, and a small runner of their own, can use it too.

func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
func await_<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    var r: Result<T, Error>?
    Task { do { r = .success(try await op()) } catch { r = .failure(error) } }
    spin(120) { r != nil }
    return r!
}
func fetch(_ url: URL, range: String? = nil) -> (Int, Data, [AnyHashable: Any]) {
    var req = URLRequest(url: url); if let range { req.setValue(range, forHTTPHeaderField: "Range") }
    let r = await_ { try await URLSession.shared.data(for: req) }
    let (d, resp) = try! r.get(); let h = resp as! HTTPURLResponse
    return (h.statusCode, d, h.allHeaderFields)
}
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
