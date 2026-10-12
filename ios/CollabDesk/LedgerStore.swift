import Foundation

extension DeskStore {
    func saveLibrary(existing: RecordLibrary?, name: String, fields: [LedgerField], views: [LedgerViewDefinition], workerAccess: String) async -> Bool {
        guard snapshot.me.privileged else { error = "记录库由 Leader 或用户管理。"; return false }
        let fields = fields.map { f -> LedgerField in var value=f; if !["select","status"].contains(f.type) { value.options=nil }; return value }
        do {
            guard fields.count<=30,views.count<=12,Set(fields.map(\.id)).count==fields.count else { throw DeskError(message:"字段重复或数量超出限制") }
            for row in (snapshot.records ?? []).filter({ $0.libraryId==existing?.id }) { try LedgerValidation.values(row.values,fields:fields,members:snapshot.members,strictMembers:isDemo) }
            let known=Set(fields.map(\.id)+["title","createdAt","updatedAt"])
            guard views.allSatisfy({ v in (v.filters ?? []).allSatisfy { known.contains($0.fieldId) } && (v.sorts ?? []).allSatisfy { known.contains($0.fieldId) } }) else { throw DeskError(message:"视图引用了已移除的字段，请先调整视图") }
        } catch { self.error=error.localizedDescription; return false }
        if isDemo {
            if let existing, snapshot.libraries?.first(where: { $0.id==existing.id })?.version != existing.version { error="记录库已更新，请刷新"; return false }
            let stamp = DeskDate.string(), id = existing?.id ?? ((snapshot.libraries ?? []).map(\.id).max() ?? 0) + 1
            let lib = RecordLibrary(id: id, name: name, fields: fields, views: views, workerAccess: workerAccess,
                                    version: (existing?.version ?? 0) + 1, createdBy: existing?.createdBy ?? snapshot.me.id, createdAt: existing?.createdAt ?? stamp, updatedAt: stamp)
            if let i = snapshot.libraries?.firstIndex(where: { $0.id == id }) { snapshot.libraries?[i] = lib }
            else { snapshot.libraries = (snapshot.libraries ?? []) + [lib] }
            return persistDemo()
        }
        let encoder = JSONEncoder()
        do {
            let f = try JSONSerialization.jsonObject(with: encoder.encode(fields)), v = try JSONSerialization.jsonObject(with: encoder.encode(views))
            var payload: [String: Any] = ["name":name, "fields":f, "views":v, "workerAccess":workerAccess]
            if let existing { payload["version"] = existing.version }
            return await write(path: existing.map { "/v1/libraries/\($0.id)/settings" } ?? "/v1/libraries", payload: payload)
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveRecord(library: RecordLibrary, existing: LedgerRecord?, title: String, values: [String: JSONValue], body: String, taskIds: [String], archived: Bool = false) async -> Bool {
        do {
            guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=200,body.count<=30000 else { throw DeskError(message:"名称或正文长度有误") }
            try LedgerValidation.values(values,fields:library.fields,members:snapshot.members,strictMembers:isDemo)
        } catch { self.error=error.localizedDescription; return false }
        if isDemo {
            if let existing, snapshot.records?.first(where: { $0.id==existing.id })?.version != existing.version { error="记录已更新，请刷新"; return false }
            let stamp = DeskDate.string(), id = existing?.id ?? ((snapshot.records ?? []).map(\.id).max() ?? 0) + 1
            let record = LedgerRecord(id:id, libraryId:library.id, title:title, values:values, body:body, archived:archived,
                                      version:(existing?.version ?? 0) + 1, taskIds:taskIds, createdBy:existing?.createdBy ?? snapshot.me.id, createdAt:existing?.createdAt ?? stamp, updatedAt:stamp)
            if let i = snapshot.records?.firstIndex(where: { $0.id == id }) { snapshot.records?[i] = record }
            else { snapshot.records = [record] + (snapshot.records ?? []) }
            let e = JSONEncoder()
            snapshot.recordEvents = [RecordHistory(id: ((snapshot.recordEvents ?? []).map(\.id).max() ?? 0) + 1, libraryId:library.id, recordId:id,
                                                  kind:existing == nil ? "created" : "updated", actorId:snapshot.me.id, actorName:snapshot.me.name,
                                                  before:existing.flatMap { try? JSONDecoder().decode(JSONValue.self, from:e.encode($0)) },
                                                  after:try? JSONDecoder().decode(JSONValue.self, from:e.encode(record)), timestamp:stamp)] + (snapshot.recordEvents ?? [])
            return persistDemo()
        }
        var payload: [String: Any] = ["title":title, "values":values.mapValues(\.any), "body":body, "archived":archived]
        if snapshot.me.privileged || existing == nil { payload["taskIds"] = taskIds }
        if let existing { payload["version"] = existing.version }
        return await write(path: existing.map { "/v1/records/\($0.id)" } ?? "/v1/libraries/\(library.id)/records", payload:payload)
    }
    func importRecords(library: RecordLibrary, format: String, content: String) async -> Bool {
        do {
            let rows=try LedgerValidation.imported(content,format:format,library:library)
            for r in rows {
                guard !r.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,r.title.count<=200,(r.body ?? "").count<=30000,
                      (r.taskIds ?? []).allSatisfy({ id in snapshot.tasks.contains { $0.id==id } }) else { throw DeskError(message:"记录名称、正文或关联任务有误") }
                try LedgerValidation.values(r.values ?? [:],fields:library.fields,members:snapshot.members,strictMembers:isDemo)
            }
            if isDemo {
                guard snapshot.me.privileged else { error="批量导入由 Leader 或用户操作"; return false }
                let original=snapshot, stamp=DeskDate.string(); var id=(snapshot.records ?? []).map(\.id).max() ?? 0
                var added:[LedgerRecord]=[]
                for r in rows { id+=1; added.append(LedgerRecord(id:id,libraryId:library.id,title:r.title,values:r.values ?? [:],body:r.body ?? "",archived:false,version:1,taskIds:r.taskIds ?? [],createdBy:snapshot.me.id,createdAt:stamp,updatedAt:stamp)) }
                snapshot.records=Array(added.reversed())+(snapshot.records ?? [])
                var eventID=(snapshot.recordEvents ?? []).map(\.id).max() ?? 0
                for r in added { eventID+=1; snapshot.recordEvents = [RecordHistory(id:eventID,libraryId:library.id,recordId:r.id,kind:"imported",actorId:snapshot.me.id,actorName:snapshot.me.name,before:nil,after:try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(r)),timestamp:stamp)]+(snapshot.recordEvents ?? []) }
                let saved=persistDemo(); if !saved { snapshot=original }; return saved
            }
            return await write(path:"/v1/libraries/\(library.id)/import", payload:["format":format, "content":content])
        } catch { self.error=error.localizedDescription; return false }
    }

    func escalateAuthorization(_ item: AuthorizationRequest, note: String) async -> Bool {
        guard snapshot.me.role == "leader", item.state == "pending_leader" else { error = "当前申请不在 Leader 审批阶段。"; return false }
        if isDemo {
            guard let i = snapshot.authorizations?.firstIndex(where: { $0.id == item.id }) else { return false }
            snapshot.authorizations?[i].reviewer = "user"; snapshot.authorizations?[i].state = "awaiting_user"
            snapshot.authorizations?[i].version += 1; snapshot.authorizations?[i].updatedAt = DeskDate.string()
            snapshot.authorizationEvents = [AuthorizationEvent(id: ((snapshot.authorizationEvents ?? []).map(\.id).max() ?? 0) + 1, authorizationId:item.id,
                taskId:item.taskId, kind:"escalated_to_user", actorId:snapshot.me.id, actorName:snapshot.me.name, body:note, timestamp:DeskDate.string())] + (snapshot.authorizationEvents ?? [])
            return persistDemo()
        }
        return await write(path:"/v1/authorizations/\(item.id)/escalate", payload:["version":item.version,"note":note])
    }
}
