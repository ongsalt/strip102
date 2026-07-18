import Dispatch
import Foundation
import Synchronization

#if canImport(WinSDK)
  import WinSDK
#endif

func getRealCoreCount() -> Int {
  #if canImport(WinSDK)
    var bufferSize: DWORD = 0

    // 1. Determine the required buffer size
    GetLogicalProcessorInformationEx(RelationProcessorCore, nil, &bufferSize)
    guard GetLastError() == DWORD(ERROR_INSUFFICIENT_BUFFER) else {
      return 0
    }

    // 2. Allocate the memory buffer
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(bufferSize),
      alignment: MemoryLayout<SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>.alignment
    )
    defer { buffer.deallocate() }

    // 3. Retrieve the actual processor information
    guard
      GetLogicalProcessorInformationEx(
        RelationProcessorCore,
        buffer.assumingMemoryBound(to: SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX.self),
        &bufferSize
      )
    else {
      return 0
    }

    // 4. Parse the buffer and count the core structures.
    // Entries are variable-length; only the fixed header (Relationship, Size)
    // is read, since Size may be smaller than the full struct's union.
    var physicalCores = 0
    var offset = 0

    while offset < Int(bufferSize) {
      let entry = buffer.advanced(by: offset)
      let relationship = entry.loadUnaligned(as: LOGICAL_PROCESSOR_RELATIONSHIP.self)
      let size = entry.loadUnaligned(fromByteOffset: 4, as: DWORD.self)

      if relationship == RelationProcessorCore {
        physicalCores += 1
      }

      offset += Int(size)
    }

    return physicalCores
  #else
    // TODO: fix hyperthreading bs
    return ProcessInfo.processInfo.processorCount / 2
  #endif
}

func dispatch<T>(count: Int, task: (Int) -> T) -> [T] {
  nonisolated(unsafe) let task = task

  return Array(capacity: count) { out in
    let coreCount = getRealCoreCount()
    let next = Atomic(0)
    nonisolated(unsafe) var _out = out

    DispatchQueue.concurrentPerform(iterations: coreCount) { index in
      while true {
        let i = next.add(1, ordering: .relaxed).oldValue
        guard i < count else { break }
        _out[i] = task(i)
      }
    }
    
    out = _out
  }

}
