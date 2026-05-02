import Foundation

struct DownloadRequest {
    var id: UUID
    var remoteURL: URL
    var destinationURL: URL
}

enum DownloadEvent {
    case progress(UUID, Double)
    case finished(UUID, URL)
    case failed(UUID, String)
}

@MainActor
final class BackgroundDownloadService: NSObject, URLSessionDownloadDelegate {
    private var continuations: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var destinations: [UUID: URL] = [:]
    private var taskIDs: [Int: UUID] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.molan.reader.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func download(_ request: DownloadRequest) -> AsyncStream<DownloadEvent> {
        AsyncStream { continuation in
            continuations[request.id] = continuation
            destinations[request.id] = request.destinationURL
            let task = session.downloadTask(with: request.remoteURL)
            task.taskDescription = request.id.uuidString
            taskIDs[task.taskIdentifier] = request.id
            task.resume()
        }
    }

    func events(for request: DownloadRequest) -> AsyncStream<DownloadEvent> {
        AsyncStream { continuation in
            continuations[request.id] = continuation
            destinations[request.id] = request.destinationURL
        }
    }

    func recover(_ requests: [DownloadRequest]) async -> [UUID] {
        let requestMap = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        let tasks = await session.allTasks
        var recovered: [UUID] = []
        for task in tasks {
            guard let description = task.taskDescription,
                  let id = UUID(uuidString: description),
                  let request = requestMap[id] else {
                continue
            }
            destinations[id] = request.destinationURL
            taskIDs[task.taskIdentifier] = id
            recovered.append(id)
            task.resume()
        }
        return recovered
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            handleFinished(downloadTask: downloadTask, location: location)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            handleCompleted(task: task, error: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            handleProgress(downloadTask: downloadTask, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }

    private func handleFinished(downloadTask: URLSessionDownloadTask, location: URL) {
        guard let id = id(for: downloadTask), let destination = destinations[id] else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuations[id]?.yield(.finished(id, destination))
            continuations[id]?.finish()
        } catch {
            continuations[id]?.yield(.failed(id, error.localizedDescription))
            continuations[id]?.finish()
        }
        cleanup(id: id, taskIdentifier: downloadTask.taskIdentifier)
    }

    private func handleCompleted(task: URLSessionTask, error: Error?) {
        guard let error, let id = id(for: task) else { return }
        continuations[id]?.yield(.failed(id, error.localizedDescription))
        continuations[id]?.finish()
        cleanup(id: id, taskIdentifier: task.taskIdentifier)
    }

    private func handleProgress(downloadTask: URLSessionDownloadTask, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let id = id(for: downloadTask) else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        continuations[id]?.yield(.progress(id, progress))
    }

    private func id(for task: URLSessionTask) -> UUID? {
        if let description = task.taskDescription, let id = UUID(uuidString: description) {
            return id
        }
        return taskIDs[task.taskIdentifier]
    }

    private func cleanup(id: UUID, taskIdentifier: Int) {
        continuations[id] = nil
        destinations[id] = nil
        taskIDs[taskIdentifier] = nil
    }
}
