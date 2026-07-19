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

/// Distributes `count` tasks over `threads` workers, each worker pulling the next task off a
/// shared atomic counter, so uneven task costs balance themselves. `thread` is stable per
/// worker — use it to index per-thread resources (arenas, scratch buffers)
func parallelFor(count: Int, threads: Int, _ body: (_ task: Int, _ thread: Int) -> Void) {
  nonisolated(unsafe) let body = body
  let next = Atomic(0)

  DispatchQueue.concurrentPerform(iterations: threads) { thread in
    while true {
      let task = next.add(1, ordering: .relaxed).oldValue
      guard task < count else { break }
      body(task, thread)
    }
  }
}

extension Collection where Index == Int {
  func parallelMap<Output>(threads: Int, _ body: (_ item: Element, _ thread: Int) -> Output) -> [Output] {
    Array(unsafeUninitializedCapacity: self.count) { out, wrote in
      wrote = self.count
      nonisolated(unsafe) let buffer = out
      parallelFor(count: self.count, threads: threads) { index, thread in
        let res = body(self[index], thread)
        buffer.initializeElement(at: index, to: res)
      }
    }
  }
}
