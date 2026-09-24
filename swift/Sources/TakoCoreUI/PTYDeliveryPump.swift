import Foundation

/// Bounded, backpressured delivery of PTY bytes to a target queue.
///
/// A PTY reader normally runs on a background queue while terminal parsing and
/// rendering are main-thread confined. Waiting for each callback to complete
/// permits bounded read-ahead while the target is busy. This preserves kernel
/// backpressure without paying parsing and rendering overhead for every read.
public enum PTYDeliveryPump {
    /// Read and deliver bytes in order, with at most one callback in flight.
    ///
    /// Chunks read while the target queue processes the preceding callback are
    /// coalesced into the next batch, up to `maxBufferedBytes`. Interactive
    /// traffic still dispatches immediately because the first chunk never
    /// waits for a timer or a minimum batch size.
    ///
    /// **`readNextIfAvailable` is what makes coalescing possible.** The pump
    /// will not take a blocking read while it is already holding bytes,
    /// because a stream that goes quiet at that moment leaves them stranded
    /// until it speaks again. Given a non-blocking read, a batch grows from
    /// whatever is already waiting and simply ends when nothing is. Without
    /// one, every blocking read is delivered on its own: still ordered, still
    /// bounded, just unbatched.
    ///
    /// `onExit` is delivered only after the final `onData` callback completes.
    /// This function must run off `targetQueue`, because it deliberately blocks
    /// the calling thread when the bounded read-ahead buffer is full.
    public static func pump(
        readNext: () -> Data?,
        readNextIfAvailable: (() -> Data?)? = nil,
        onData: @escaping (Data) -> Void,
        onExit: @escaping () -> Void,
        targetQueue: DispatchQueue = .main,
        maxBufferedBytes: Int = 4 * 1024 * 1024
    ) {
        precondition(maxBufferedBytes > 0)

        var current = readNext()
        while let batch = current, !batch.isEmpty {
            let delivered = batch
            let completion = DispatchSemaphore(value: 0)
            targetQueue.async {
                onData(delivered)
                completion.signal()
            }

            var next = Data()
            var callbackFinished = false

            // Build the next batch only while the preceding callback remains
            // busy.
            //
            // The read blocks only while nothing is being held. That
            // distinction is the whole correctness of this loop: a blocking
            // read taken with bytes already in `next` sits there holding them
            // for as long as the stream stays quiet, and a stream that has
            // just gone quiet is exactly when the last thing read matters
            // most -- an interrupted `tail -f` and the shell prompt printed
            // after it. Those bytes were stranded until something else
            // arrived to unblock the read, which is why pressing Enter
            // appeared to summon the prompt.
            //
            // With something held, only bytes already waiting in the kernel
            // are taken, and running out simply ends the batch.
            while next.count < maxBufferedBytes && !callbackFinished {
                let chunk: Data?
                if next.isEmpty {
                    // Nothing is being held, so blocking here is safe and is
                    // how light traffic avoids a timer.
                    chunk = readNext()
                } else if let readNextIfAvailable {
                    chunk = readNextIfAvailable()
                } else {
                    // No way to look without committing. Blocking is the
                    // lesser risk: stopping early would leave a caller whose
                    // callback waits on further reads with nothing to wait
                    // for.
                    chunk = readNext()
                }
                guard let chunk, !chunk.isEmpty else {
                    break
                }
                next.append(chunk)
                callbackFinished = completion.wait(timeout: .now()) == .success
            }

            // A fast parser may finish before the reader can accumulate a
            // batch. Drain bytes that are already waiting in the kernel so a
            // burst still produces one frame, without waiting for future
            // interactive input or introducing a coalescing timer.
            if callbackFinished, let readNextIfAvailable {
                while next.count < maxBufferedBytes,
                      let chunk = readNextIfAvailable(), !chunk.isEmpty {
                    next.append(chunk)
                }
            }

            if !callbackFinished {
                completion.wait()
            }
            current = next.isEmpty ? nil : next
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        targetQueue.async {
            onExit()
            exitSemaphore.signal()
        }
        exitSemaphore.wait()
    }

    /// Preserved [UInt8] overload delegating to the primary Data pump.
    public static func pump(
        readNext: () -> [UInt8]?,
        readNextIfAvailable: (() -> [UInt8]?)? = nil,
        onData: @escaping ([UInt8]) -> Void,
        onExit: @escaping () -> Void,
        targetQueue: DispatchQueue = .main,
        maxBufferedBytes: Int = 4 * 1024 * 1024
    ) {
        pump(
            readNext: { readNext().map { Data($0) } },
            readNextIfAvailable: readNextIfAvailable.map { r in { r().map { Data($0) } } },
            onData: { data in onData([UInt8](data)) },
            onExit: onExit,
            targetQueue: targetQueue,
            maxBufferedBytes: maxBufferedBytes
        )
    }
}
