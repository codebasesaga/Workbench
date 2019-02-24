import PMKCloudKit
import Foundation
import PromiseKit
import CloudKit
import Dispatch
import Bakeware
import Path

public extension Item {
    /// returns a new promise that is intended for user-communication only
    private func reflect() -> Promise<Void> {
        guard case .networking(let promise) = status else {
            return Promise(error: StateMachineError())
        }

        return promise.done {
            // see if we’re done or not
            guard case .networking(let ongoingPromise) = self.status else { return }

            guard ongoingPromise === promise else {
                // we are no longer the last promise in the chain, forget about
                // this promise, it is now irrelevant
                throw PMKError.cancelled
            }

            switch promise.result {
            case .none:
                throw StateMachineError()

            case .fulfilled?:
                self.status = .init(record: self.record)

            case .rejected(let error)?:
                self.status = .error(error)
                throw error
            }
        }
    }

    private func validate(record: CKRecord) {
        assert(record === self.record)
    }

    func upload() -> Promise<Void>? {
        dispatchPrecondition(condition: .onQueue(.main))
        
        func go() -> Promise<Void> {
            return DispatchQueue.global().async(.promise) {
                { ($0, $0.md5) }(try Data(contentsOf: self.path))
            }.done { data, md5 in
                self.record[.data] = data as CKRecordValue
                self.record[.checksum] = md5 as CKRecordValue
            }.then {
                db.save(self.record).done {
                    assert($0 === self.record)
                }
            }
        }

        switch status {
        case .error:
            print("warning: will not upload while in error state")
            return nil
        case .networking(let promise):
            status = .networking(promise.then(go))
        case .synced:
            status = .networking(go())
        }

        return reflect()
    }

    func download() -> Promise<Void>? {
        dispatchPrecondition(condition: .onQueue(.main))

        guard case .error = status else {
            print("warning: will not download while in non-error state")
            return nil
        }

        status = .networking(firstly {
            db.fetch(withRecordID: record.recordID)
        }.get {
            self.record = $0
        }.compactMap {
            $0[.data] as? Data
        }.done {
            try $0.write(to: self.path)
        })

        return reflect()
    }

    func replace() -> Promise<Void>? {
        dispatchPrecondition(condition: .onQueue(.main))

        guard case .error = status else {
            return nil
        }

        let op = CKModifyRecordsOperation()
        op.recordsToSave = [record]
        op.savePolicy = .changedKeys

        let p = DispatchQueue.global().async(.promise) {
            { ($0, $0.md5) }(try Data(contentsOf: self.path))
        }.done { data, md5 in
            self.record[.data] = data as CKRecordValue
            self.record[.checksum] = md5 as CKRecordValue
        }.then {
            Promise<Void> { seal in
                op.modifyRecordsCompletionBlock = { _, _, error in seal.resolve(error) }
                db.add(op)
            }
        }

        status = .networking(p)

        return reflect()
    }

    func delete() -> Promise<Void>? {
        dispatchPrecondition(condition: .onQueue(.main))

        switch status {
        case .synced, .error:
            return db.delete(withRecordID: record.recordID).asVoid()
        case .networking:
            return nil
        }
    }
}
