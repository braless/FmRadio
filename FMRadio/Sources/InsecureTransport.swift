import Foundation
import AVFoundation

/// 放宽 TLS 证书校验的 URLSession 代理。
/// 部分电台流使用自签名/过期证书，AVPlayer 默认会拒绝并报
/// "The certificate for this server is invalid"。此代理仅对音频流生效。
final class InsecureTransport: NSObject, URLSessionDelegate {
    static let shared = InsecureTransport()

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "FMRadio/2.3"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
