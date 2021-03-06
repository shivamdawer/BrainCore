// Copyright © 2016 Venture Media Labs. All rights reserved.
//
// This file is part of BrainCore. The full BrainCore copyright notice,
// including terms governing use, modification, and redistribution, is
// contained in the file LICENSE at the root of the source code distribution
// tree.

import Foundation
import Metal

/// A `Runner` that performs feed-forward passes on a network.
///
/// `Evaluator` is optimized for running a single pass at a time (batch size of one). It maximizes GPU parallelism by enqueing sequential runs a few at a time.
///
/// - SeeAlso: `Runner`, `Trainer`
public class Evaluator: Runner {

    /// The maximum number of instances to enqueue to the GPU at a time.
    let instanceCount = 3
    var instances = [Instance]()
    var nextInstanceIndex = 0
    var inflightSemaphore: dispatch_semaphore_t
    var queue: dispatch_queue_t

    /// Creates an `Evaluator` for the given network definition.
    ///
    /// - Parameter net:    network definition.
    /// - Parameter device: Metal device to use when running.
    public init(net: Net, device: MTLDevice) throws {
        queue = dispatch_queue_create("BrainCore.Evaluator", DISPATCH_QUEUE_SERIAL)
        inflightSemaphore = dispatch_semaphore_create(instanceCount)
        try super.init(net: net, device: device, batchSize: 1, backwards: false)

        for _ in 0..<instanceCount {
            let forwardInstance = Instance(buffers: net.buffers, device: device, batchSize: 1)
            instances.append(forwardInstance)
        }
    }

    /// Executes a paticular `Invocation` on the GPU.
    ///
    /// This is used to perform operations on the GPU. Usually you would not perfom invocations directly, but this can be used to perform updates to the buffers outside of a feed-forward pass.
    ///
    /// - Parameter invocations: array of invocations to execute.
    /// - Parameter completion:  closure to execute when the invocation completes.
    public func call(invocations: [Invocation], completion: (() -> Void)?) {
        dispatch_sync(queue) {
            self.callInQueue(invocations, completion: completion)
        }
    }

    func callInQueue(invocations: [Invocation], completion: (() -> Void)?) {
        let buffer = commandQueue.commandBuffer()
        for invocation in invocations {
            try! Runner.encode(invocation: invocation, commandBuffer: buffer)
        }

        buffer.addCompletedHandler() { commandBuffer in
            dispatch_async(self.queue) {
                completion?()
            }
        }
        buffer.commit()
    }

    /// Performs a feed-forward pass on the network.
    ///
    /// - Important: Always call this method from the same serial queue.
    ///
    /// - Parameter completion: closure to execute when the evaluation finishes. It gets passed a snapshot of the network results.
    public func evaluate(completion: ((Snapshot) -> Void)) {
        dispatch_semaphore_wait(inflightSemaphore, DISPATCH_TIME_FOREVER)

        let instance = instances[nextInstanceIndex]
        instance.reset()
        nextInstanceIndex = (nextInstanceIndex + 1) % instanceCount

        commandQueue.insertDebugCaptureBoundary()

        // Collect all data
        for n in net.dataNodes.values {
            let dataLayer = n.layer as! DataLayer

            if let netBuffer = n.outputBuffer {
                guard let buffer = instance.buffers[netBuffer.id] else {
                    fatalError("Output buffer for \(dataLayer.name) not found.")
                }
                fillBuffer(buffer, start: n.outputRange.startIndex, withElements: dataLayer.nextBatch(1))
            }
            instance.closeNode(n)
            instance.openOutputsOf(n)
            instance.finishNode(n)
        }

        dispatch_sync(queue) {
            self.processNodesOfInstance(instance, completion: completion)
        }
    }

    func processNodesOfInstance(instance: Instance, completion: ((Snapshot) -> Void)) {
        while !instance.openNodes.isEmpty {
            let node = instance.openNodes.popLast()!
            if instance.isClosed(node) {
                continue
            }

            guard let forwardLayer = node.layer as? ForwardLayer else {
                continue
            }

            guard let _ = node.inputBuffer, _ = node.outputBuffer else {
                preconditionFailure("Layer '\(node.layer.name)' is missing a buffer")
            }

            let buffer = commandQueue.commandBuffer()
            for invocation in forwardLayer.forwardInvocations {
                for buffer in invocation.buffers {
                    guard let netBuffer = buffer.netBuffer else { continue }
                    if let metalBuffer = instance.buffers[netBuffer.id] {
                        buffer.metalBuffer = metalBuffer
                    }
                }
                try! Runner.encode(invocation: invocation, commandBuffer: buffer)
            }

            buffer.addCompletedHandler() { commandBuffer in
                dispatch_async(self.queue) {
                    instance.finishNode(node)
                    if instance.isFinished() {
                        self.finishInstance(instance, completion: completion)
                    }
                }
            }
            buffer.commit()
            instance.closeNode(node)
            instance.openOutputsOf(node)
        }
    }

    func finishInstance(instance: Instance, completion: ((Snapshot) -> Void)) {
        for n in net.sinkNodes.values {
            let sinkLayer = n.layer as! SinkLayer
            if let netBuffer = n.inputBuffer {
                guard let buffer = instance.buffers[netBuffer.id] else {
                    fatalError("Layer '\(n.layer.name)'s input buffer was not found.")
                }

                sinkLayer.consume(valueArrayFromBuffer(buffer, start: n.inputRange.startIndex))
            }
        }

        completion(Snapshot(net: self.net, forwardBuffers: instance.buffers))
        dispatch_semaphore_signal(self.inflightSemaphore)
    }
}
