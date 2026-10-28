@preconcurrency import CoreNFC
import Foundation
import NagKit

enum NFCKeyError: LocalizedError {
    case unavailable
    case unsupportedTag

    var errorDescription: String? {
        switch self {
        case .unavailable: "This iPhone can't read NFC tags."
        case .unsupportedTag: "That kind of tag isn't supported. Try an NFC sticker (NTAG213/215/216)."
        }
    }
}

/// Reads an NFC tag's hardware ID and returns its fingerprint. Any sticker, card or key fob works,
/// including the ones sold for focus apps. Nothing is written to the tag.
final class NFCKeyReader: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
    static var isAvailable: Bool {
        NFCTagReaderSession.readingAvailable
    }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<String, any Error>?

    /// Shows the system scan sheet. Throws if the user cancels or the read fails.
    @MainActor
    func scan(prompt: String) async throws -> String {
        guard Self.isAvailable else { throw NFCKeyError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil) else {
                continuation.resume(throwing: NFCKeyError.unavailable)
                return
            }
            self.continuation = continuation
            self.session = session
            session.alertMessage = prompt
            session.begin()
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        finish(.failure(error))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        // Core NFC calls back on the session's queue, where these are used exclusively.
        nonisolated(unsafe) let tag = first
        nonisolated(unsafe) let session = session
        session.connect(to: tag) { [weak self] error in
            if error != nil {
                session.invalidate(errorMessage: "Couldn't read that tag. Hold still and try again.")
                return
            }
            guard let identifier = Self.identifier(of: tag) else {
                session.invalidate(errorMessage: NFCKeyError.unsupportedTag.localizedDescription)
                self?.finish(.failure(NFCKeyError.unsupportedTag))
                return
            }
            session.alertMessage = "Got it."
            session.invalidate()
            self?.finish(.success(KeyFingerprint.nfc(identifier)))
        }
    }

    private static func identifier(of tag: NFCTag) -> Data? {
        switch tag {
        case .miFare(let tag): tag.identifier
        case .iso15693(let tag): tag.identifier
        case .iso7816(let tag): tag.identifier
        case .feliCa(let tag): tag.currentIDm
        @unknown default: nil
        }
    }

    /// Resumes once; later callbacks (invalidation after success) are ignored.
    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }
}
