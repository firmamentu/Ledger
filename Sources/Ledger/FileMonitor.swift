import Foundation
import CoreServices
import os

/// FSEvents 监听：17 根 + ~/.Trash，FileEvents 标志、latency 0.5s（§3）。
/// 回调只做两件事：把事件转发给 ScanService（索引写在那里与扫描串行），
/// 以及持久化 last_fsevent_id。~/.Trash 事件只推进 eventId，不做索引处理（M4 卸载判定用）。
final class FileMonitor {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "monitor")
    private let database: Database
    private let scanService: ScanService
    private let model: AppModel
    private let queue = DispatchQueue(label: "com.ledger.app.events", qos: .utility)
    private var stream: FSEventStreamRef?

    init(database: Database, scanService: ScanService, model: AppModel) {
        self.database = database
        self.scanService = scanService
        self.model = model
    }

    /// 从 eventID 开始监听；FSEvents 会自动重放该 id 之后的事件（重启对账，§5.4）。
    func start(since eventID: FSEventStreamEventId) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // 注意：不加 kFSEventStreamCreateFlagUseCFTypes——回调按 C 字符串读路径，
        // 该标志会把 eventPaths 变成 CFString 对象数组，导致悬空指针崩溃
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        let paths = ScanRoots.watchPaths.map { $0.path } as CFArray

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, _, eventIDs in
                guard let info else { return }
                let monitor = Unmanaged<FileMonitor>.fromOpaque(info).takeUnretainedValue()
                let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var collected: [String] = []
                collected.reserveCapacity(count)
                var last: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                for i in 0..<count {
                    collected.append(String(cString: paths[i]))
                    last = eventIDs[i]
                }
                monitor.handle(events: collected, lastEventID: last)
            },
            &context,
            paths,
            eventID,
            0.5,
            flags
        ) else {
            logger.error("FSEventStreamCreate 失败")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        logger.notice("FSEvents 已启动（since=\(eventID)）")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func handle(events: [String], lastEventID: FSEventStreamEventId) {
        let paths = events.filter { !ScanRoots.isUnderTrash($0) }  // ~/.Trash：M4 卸载判定
        if !paths.isEmpty {
            scanService.applyFileEvents(paths: paths)
            DispatchQueue.main.async { self.model.eventsProcessed += paths.count }
        }

        // 每批推进持久化事件 id（重启对账的起点）；写失败下次启动退化成全量重扫（安全）
        if lastEventID != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            do {
                try database.metaSet("last_fsevent_id", String(lastEventID))
            } catch {
                logger.error("事件 id 落盘失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
