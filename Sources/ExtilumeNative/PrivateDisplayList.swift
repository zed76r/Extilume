import Darwin

struct PrivateDisplayListRead {
    let apiFound: Bool
    let displayIDs: [UInt32]?
}

private typealias PrivateDisplayListReader = @convention(c) (
    UInt32,
    UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<UInt32>?
) -> Int32

func validatedPrivateDisplayIDs(storage: [UInt32], count: UInt32, status: Int32) -> [UInt32]? {
    // shortcut: 缓冲区填满即拒绝，需支持 128 个及以上显示槽时改为有界扩容。
    guard status == 0, UInt64(count) < UInt64(storage.count) else { return nil }
    let ids = Array(storage.prefix(Int(count)))
    return ids.contains(0) ? nil : ids
}

func readPrivateDisplaySlots() -> PrivateDisplayListRead {
    let candidates = [
        ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSGetDisplayList"),
        ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSGetDisplayList")
    ]
    for (path, name) in candidates {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
        guard let symbol = dlsym(handle, name) else {
            dlclose(handle)
            continue
        }
        let read = unsafeBitCast(symbol, to: PrivateDisplayListReader.self)
        var storage = [UInt32](repeating: 0, count: 128)
        var count: UInt32 = 0
        let status = storage.withUnsafeMutableBufferPointer { ids in
            read(UInt32(ids.count), ids.baseAddress, &count)
        }
        dlclose(handle)
        return PrivateDisplayListRead(
            apiFound: true,
            displayIDs: validatedPrivateDisplayIDs(storage: storage, count: count, status: status)
        )
    }
    return PrivateDisplayListRead(apiFound: false, displayIDs: nil)
}
